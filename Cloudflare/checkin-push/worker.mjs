// Worker `betterbahn-push`: push notifications for new check-ins of the people a Träwelling user follows
// (#266) and about the user's own check-ins (#447: likes, people joining the same train), so they arrive
// even while iOS doesn't let the app look itself.
//
// Turning them on in the app signs in with Träwelling a second time, for this Worker only and with the
// read-only scopes `read-statuses` and `read-notifications`: the app sends the authorization code here and
// the Worker keeps that login (encrypted), never the app's own. Träwelling's access tokens last an hour and
// each refresh token works once, so sharing the app's login would log one of the two out.
//
// Every minute the cron trigger looks at the subscriptions due in that minute: Träwelling's dashboard for
// followed check-ins, its notifications for likes and fellow travellers, then an APNs notification for
// each one that is new since the last look. The first look only remembers what is there already.
//
// Likes and fellow travellers also arrive right away through a Träwelling webhook (`/traewelling/webhook`),
// made with the Worker's login while TRAEWELLING_WEBHOOKS is "true"; the look every 2 minutes stays as the
// fallback (a webhook Träwelling turned off after failed deliveries, logins from before).
//
// It also looks after the journeys of regular trips (#397, `/commutes`, see commute.mjs).

import { APNs } from "../shared/apns.mjs";
import { TOKEN_HEADER, fromBase64, toBase64, unauthorized, verifyToken } from "../shared/appattest.mjs";
import { handleCommute, processDueCommutes } from "./commute.mjs";

export { signProviderToken } from "../shared/apns.mjs";

const TRAEWELLING = "https://traewelling.de";
const USER_AGENT = "BetterBahn-Push (+https://betterbahn.betterbahn.workers.dev/support)";
export const SCOPE = "read-statuses read-notifications";
/// What a subscription is notified about: followed check-ins (dashboard), likes on the user's own check-ins
/// and people checking in on the same train (Träwelling's notifications `StatusLiked`, `UserJoinedConnection`).
export const KINDS = ["followed", "likes", "companions"];
const NOTIFICATION_KINDS = ["likes", "companions"];
const MINUTE = 60;
/// How many status IDs are remembered: far more than the people followed are ever checked in at once.
const REMEMBERED = 200;
/// Rides that leave within this time (by plan) already count as checked in, as in the app.
const BOARDING_WINDOW = 20 * MINUTE;
const DEVICE_TOKEN_PATTERN = /^[0-9a-f]{64,200}$/;
const ID_PATTERN = /^[0-9a-f]{32}$/;
const MAX_BODY_BYTES = 16 * 1024;
const MAX_WEBHOOK_BYTES = 64 * 1024;
export const WEBHOOK_PATH = "/traewelling/webhook";

// MARK: - HTTP

/// POST   /subscriptions      { code, codeVerifier, deviceToken, sandbox, userId, kinds } → 201 { id, secret }
/// PUT    /subscriptions/<id> { secret, deviceToken, sandbox, kinds }                     → 200 {} (404: gone)
/// DELETE /subscriptions/<id> { secret }                                            → 204
/// PUT    /commutes/<id>      { secret, deviceToken, sandbox, journeys }            → 200 { watched } (see commute.mjs)
/// GET    /login-options                                                           → 200 { authorize } (see `loginOptions`)
/// POST   /traewelling/webhook  (Träwelling, signed)                                → 200 (410: unknown webhook)
/// `kinds` (see `KINDS`, at least one) defaults to ["followed"], what apps before #447 sign up for.
export async function handleRequest(request, env = {}, now = Date.now(), deps = {}) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json(200, { ok: true });
    if (url.pathname === "/login-options") return json(200, loginOptions(env, url));
    if (url.pathname === WEBHOOK_PATH) {
        if (request.method !== "POST") return json(405, { error: "method_not_allowed" }, { Allow: "POST" });
        if (!env.DB || !env.TOKEN_KEY) return json(503, { error: "not_configured" });
        return handleWebhook(request, env, now, deps);
    }
    const commute = url.pathname.match(/^\/commutes\/([^/]+)$/);
    const match = url.pathname.match(/^\/subscriptions(?:\/([^/]+))?$/);
    if (!match && !commute) return json(404, { error: "not_found" });
    if (!env.DB || (match && !env.TOKEN_KEY)) return json(503, { error: "not_configured" });

    // Only the genuine app: an App Attest token (same TOKEN_SECRET as the other Workers), or no token
    // while ALLOW_UNATTESTED is "true" (see ../shared/appattest.mjs).
    const token = request.headers.get(TOKEN_HEADER);
    const claims = token && env.TOKEN_SECRET ? await verifyToken(token, "a", env.TOKEN_SECRET, now) : null;
    if (token ? !claims : env.ALLOW_UNATTESTED !== "true") return unauthorized();
    if (env.SUBSCRIBE_LIMITER) {
        const key = claims?.kid ?? request.headers.get("CF-Connecting-IP") ?? "unknown";
        const { success } = await env.SUBSCRIBE_LIMITER.limit({ key: String(key) });
        if (!success) return json(429, { error: "rate_limited" });
    }

    let body;
    try {
        const text = await request.text();
        if (text.length > MAX_BODY_BYTES) return json(413, { error: "too_large" });
        body = JSON.parse(text);
    } catch {
        return json(400, { error: "invalid_json" });
    }
    if (typeof body !== "object" || body === null) return json(400, { error: "invalid_json" });
    if (commute) {
        if (request.method !== "PUT") return json(405, { error: "method_not_allowed" }, { Allow: "PUT" });
        return handleCommute(commute[1], body, env, now, deps.fetch ?? fetch);
    }

    const [, id] = match;
    if (!id) {
        if (request.method !== "POST") return json(405, { error: "method_not_allowed" }, { Allow: "POST" });
        return subscribe(body, env, now, deps.fetch ?? fetch);
    }
    if (!ID_PATTERN.test(id)) return json(404, { error: "not_found" });
    const row = await env.DB.prepare("SELECT id, secret_hash, tokens, kinds, webhook_id FROM subscriptions WHERE id = ?").bind(id).first();
    if (!row || typeof body.secret !== "string" || await sha256Hex(body.secret) !== row.secret_hash) {
        return json(404, { error: "not_found" });
    }
    if (request.method === "PUT") {
        if (!isDeviceToken(body.deviceToken)) return json(400, { error: "invalid_device_token" });
        const kinds = body.kinds === undefined ? storedKinds(row.kinds) : parseKinds(body.kinds);
        if (!kinds) return json(400, { error: "invalid_kinds" });
        // What is turned on again starts over: its first look only remembers. Followed check-ins and the
        // notifications are remembered apart; any notification seen counts, so only turning the first
        // notification kind on starts those over.
        const before = storedKinds(row.kinds);
        const restartsFollowed = kinds.includes("followed") && !before.includes("followed");
        const restartsNotifications = readsNotifications(kinds) && !readsNotifications(before);
        await env.DB.prepare(
            `UPDATE subscriptions SET device_token = ?, sandbox = ?, kinds = ?${restartsFollowed ? ", known = NULL" : ""}${restartsNotifications ? ", notified = NULL" : ""} WHERE id = ?`,
        ).bind(body.deviceToken, body.sandbox ? 1 : 0, JSON.stringify(kinds), id).run();
        return json(200, {});
    }
    if (request.method === "DELETE") {
        await env.DB.prepare("DELETE FROM subscriptions WHERE id = ?").bind(id).run();
        // Ends the webhook and the Worker's Träwelling login too; nothing is lost when that fails: the token
        // expires within the hour, and the webhook's next delivery gets a 410, on which Träwelling deletes it.
        const tokens = await decryptTokens(row.tokens, id, env.TOKEN_KEY).catch(() => null);
        if (tokens && Number.isSafeInteger(row.webhook_id)) {
            await traewelling(`api/v1/webhooks/${row.webhook_id}`, tokens.access, { method: "DELETE" }, deps.fetch ?? fetch).catch(() => {});
        }
        if (tokens) await traewelling("api/v1/auth/logout", tokens.access, { method: "POST" }, deps.fetch ?? fetch).catch(() => {});
        return new Response(null, { status: 204 });
    }
    return json(405, { error: "method_not_allowed" }, { Allow: "PUT, DELETE" });
}

async function subscribe(body, env, now, fetchUpstream) {
    const { code, codeVerifier, deviceToken, sandbox, userId } = body;
    const kinds = body.kinds === undefined ? ["followed"] : parseKinds(body.kinds);
    if (typeof code !== "string" || !code || code.length > 2048 || typeof codeVerifier !== "string"
        || !/^[A-Za-z0-9._~-]{43,128}$/.test(codeVerifier)) {
        return json(400, { error: "invalid_code" });
    }
    if (!isDeviceToken(deviceToken)) return json(400, { error: "invalid_device_token" });
    if (!Number.isSafeInteger(userId) || userId <= 0) return json(400, { error: "invalid_user" });
    if (!kinds) return json(400, { error: "invalid_kinds" });

    let tokens;
    try {
        tokens = await requestTokens({
            grant_type: "authorization_code",
            client_id: env.TRAEWELLING_CLIENT_ID ?? "406",
            redirect_uri: env.TRAEWELLING_REDIRECT_URI ?? "",
            code_verifier: codeVerifier,
            code,
        }, now, fetchUpstream);
    } catch (error) {
        return json(error instanceof RejectedGrant ? 400 : 502, { error: error instanceof RejectedGrant ? "invalid_code" : "traewelling_unavailable" });
    }

    const id = randomHex(16);
    const secret = randomHex(32);
    const slot = crypto.getRandomValues(new Uint8Array(1))[0] % 60;
    // Träwelling made a webhook when the login asked for one (`loginOptions`); only its secret is kept, sealed.
    const { webhook, ...login } = tokens;
    await env.DB.prepare(
        "INSERT INTO subscriptions (id, secret_hash, device_token, sandbox, user_id, tokens, known, kinds, notified, webhook_id, webhook, slot, created) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, NULL, ?, ?, ?, ?)",
    ).bind(id, await sha256Hex(secret), deviceToken, sandbox ? 1 : 0, userId, await encryptTokens(login, id, env.TOKEN_KEY),
        JSON.stringify(kinds), webhook?.id ?? null, webhook ? await encryptTokens({ secret: webhook.secret }, id, env.TOKEN_KEY) : null,
        slot, Math.floor(now / 1000)).run();
    return json(201, { id, secret });
}

/// What the app adds to the Worker's Träwelling login: with TRAEWELLING_WEBHOOKS "true" (webhooks turned on
/// for the OAuth client, with this Worker's URL as its webhook URL) Träwelling makes a webhook for the user's
/// notifications. Without, a login asking for one would fail.
export function loginOptions(env, url) {
    if (env.TRAEWELLING_WEBHOOKS !== "true") return { authorize: {} };
    return { authorize: { trwl_webhook_url: `${url.origin}${WEBHOOK_PATH}`, trwl_webhook_events: "notification" } };
}

/// A delivery of Träwelling's webhook: one of the user's notifications, signed with the webhook's secret
/// (HMAC-SHA256 of the body, hex, header `Signature`). Träwelling waits only a second for the answer, so the
/// push is sent after it (`deps.waitUntil`). An unknown webhook gets 410, on which Träwelling deletes it.
async function handleWebhook(request, env, now, deps) {
    const body = await request.text();
    if (body.length > MAX_WEBHOOK_BYTES) return json(413, { error: "too_large" });
    const webhookID = Number(request.headers.get("X-Trwl-Webhook-Id"));
    if (!Number.isSafeInteger(webhookID) || webhookID <= 0) return json(400, { error: "invalid_webhook" });
    const row = await env.DB.prepare(
        "SELECT id, device_token, sandbox, kinds, notified, webhook FROM subscriptions WHERE webhook_id = ?",
    ).bind(webhookID).first();
    if (!row?.webhook) return json(410, { error: "gone" });
    const { secret } = await decryptTokens(row.webhook, row.id, env.TOKEN_KEY);
    if (!await validSignature(body, request.headers.get("Signature"), secret)) return json(401, { error: "invalid_signature" });

    let payload;
    try {
        payload = JSON.parse(body);
    } catch {
        return json(400, { error: "invalid_json" });
    }
    const item = payload?.event === "notification" ? payload.notification : null;
    const push = typeof item?.id === "string" && item.id.length <= 64 ? ownCheckinNotification(item, storedKinds(row.kinds)) : null;
    const notified = row.notified ? JSON.parse(row.notified) : null;
    if (!push || notified?.includes(item.id)) return json(200, {});

    const deliver = (async () => {
        const result = await new APNs(env, now, deps.fetch ?? fetch).send(row.device_token, row.sandbox, push.payload, {
            "apns-topic": env.APNS_TOPIC,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": push.collapseID,
        });
        if (result === "gone") {
            await env.DB.prepare("DELETE FROM subscriptions WHERE id = ?").bind(row.id).run();
        } else if (result === "sent" && notified) {
            // So the look every 2 minutes doesn't report it again. Before the first look nothing is remembered yet:
            // that look takes in whatever is there.
            await saveNotified(env, row.id, [...notified, item.id]);
        }
    })().catch(error => console.log(`webhook push failed: ${error?.message ?? error}`));
    if (deps.waitUntil) deps.waitUntil(deliver); else await deliver;
    return json(200, {});
}

async function validSignature(body, signature, secret) {
    if (typeof signature !== "string" || !/^[0-9a-f]{64}$/i.test(signature) || typeof secret !== "string") return false;
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const bytes = new Uint8Array(signature.match(/../g).map(byte => parseInt(byte, 16)));
    return crypto.subtle.verify("HMAC", key, bytes, new TextEncoder().encode(body));
}

/// The kinds asked for, each once in `KINDS`' order; null when one is unknown or none is given.
export function parseKinds(value) {
    if (!Array.isArray(value) || value.length === 0 || !value.every(kind => KINDS.includes(kind))) return null;
    return KINDS.filter(kind => value.includes(kind));
}

function storedKinds(stored) {
    try {
        return parseKinds(JSON.parse(stored)) ?? ["followed"];
    } catch {
        return ["followed"];
    }
}

function readsNotifications(kinds) {
    return kinds.some(kind => NOTIFICATION_KINDS.includes(kind));
}

function isDeviceToken(value) {
    return typeof value === "string" && DEVICE_TOKEN_PATTERN.test(value);
}

function json(status, body, headers = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
    });
}

// MARK: - Cron

/// Looks at the subscriptions due in this minute. Returns how many it looked at.
export async function processDueSubscriptions(env, now = Date.now(), deps = {}) {
    const fetchUpstream = deps.fetch ?? fetch;
    const interval = Math.min(60, Math.max(1, Number(env.INTERVAL_MINUTES) || 2));
    const minute = Math.floor(now / 60000) % 60;
    const { results } = await env.DB.prepare(
        "SELECT id, device_token, sandbox, user_id, tokens, known, kinds, notified FROM subscriptions WHERE slot % ? = ?",
    ).bind(interval, minute % interval).all();

    const apns = new APNs(env, now, fetchUpstream);
    for (const subscription of results ?? []) {
        try {
            await check(subscription, env, now, fetchUpstream, apns);
        } catch (error) {
            // Träwelling or APNs unreachable: the next look tries again.
            console.log(`check failed: ${error?.message ?? error}`);
        }
    }
    return results?.length ?? 0;
}

/// One look for one subscription. Writes only when something changed (a refreshed login, new check-ins
/// or notifications).
async function check(subscription, env, now, fetchUpstream, apns) {
    const { id } = subscription;
    const kinds = storedKinds(subscription.kinds);
    let tokens = await decryptTokens(subscription.tokens, id, env.TOKEN_KEY);
    let refreshed = false;
    const refresh = async () => {
        tokens = await requestTokens({
            grant_type: "refresh_token",
            client_id: env.TRAEWELLING_CLIENT_ID ?? "406",
            refresh_token: tokens.refresh,
        }, now, fetchUpstream);
        refreshed = true;
        // Saved at once: the old refresh token no longer works, even if what follows fails.
        await env.DB.prepare("UPDATE subscriptions SET tokens = ? WHERE id = ?")
            .bind(await encryptTokens(tokens, id, env.TOKEN_KEY), id).run();
    };
    /// A Träwelling page, null when it doesn't answer (the next look tries again). Throws `RejectedGrant`
    /// when the login ended (revoked on Träwelling, unused too long).
    const load = async (path) => {
        if (tokens.expires <= now / 1000 + MINUTE && !refreshed) await refresh();
        let response = await traewelling(path, tokens.access, {}, fetchUpstream);
        if (response.status === 401 && !refreshed) {
            await refresh();
            response = await traewelling(path, tokens.access, {}, fetchUpstream);
        }
        if (response.status === 401) throw new RejectedGrant();
        return response.ok ? response.json() : null;
    };
    /// "sent", or "failed" to try again on the next look; throws `DeviceGone` when APNs no longer knows the app.
    const send = async (payload, collapseID) => {
        const result = await apns.send(subscription.device_token, subscription.sandbox, payload, {
            "apns-topic": env.APNS_TOPIC,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": collapseID,
        });
        if (result === "gone") throw new DeviceGone();
        return result;
    };

    try {
        if (kinds.includes("followed")) await checkFollowed(subscription, env, now, load, send);
        if (readsNotifications(kinds)) await checkNotifications(subscription, kinds, env, load, send);
    } catch (error) {
        // The app learns it from a 404 and turns the settings off.
        if (error instanceof RejectedGrant || error instanceof DeviceGone) {
            await env.DB.prepare("DELETE FROM subscriptions WHERE id = ?").bind(id).run();
            return;
        }
        throw error;
    }
}

/// New check-ins of the people followed, from the dashboard.
async function checkFollowed(subscription, env, now, load, send) {
    let page;
    try {
        page = await load("api/v1/dashboard");
    } catch (error) {
        if (error instanceof RejectedGrant) throw error;
        return;
    }
    if (!page) return;

    const { id } = subscription;
    const running = checkedIn(page?.data ?? [], subscription.user_id, now);
    const known = subscription.known ? JSON.parse(subscription.known) : null;
    if (known === null) {
        // The first look only remembers: what runs already when the notifications start isn't news.
        await saveKnown(env, id, running.map(status => status.id));
        return;
    }
    const seen = new Set(known);
    const fresh = running.filter(status => !seen.has(status.id));
    if (fresh.length === 0) return;

    // Only what was delivered counts as reported; the others are tried again on the next look.
    const sent = [];
    for (const status of fresh) {
        const payload = notification(status);
        if (await send(payload, `followed-${payload.followedStatusID}`) === "sent") sent.push(status.id);
    }
    if (sent.length > 0) await saveKnown(env, id, [...known, ...sent]);
}

/// Likes on the user's own check-ins and people joining their train, from Träwelling's notifications
/// (first page, newest first). Every notification seen is remembered, also those of kinds turned off.
async function checkNotifications(subscription, kinds, env, load, send) {
    let page;
    try {
        page = await load("api/v1/notifications");
    } catch (error) {
        if (error instanceof RejectedGrant) throw error;
        return;
    }
    // A login from before #447 can't read them (403): it only gets followed check-ins.
    if (!page) return;

    const { id } = subscription;
    const items = (page?.data ?? []).filter(item => typeof item?.id === "string" && item.id.length <= 64);
    const notified = subscription.notified ? JSON.parse(subscription.notified) : null;
    if (notified === null) {
        await saveNotified(env, id, items.map(item => item.id));
        return;
    }
    const seen = new Set(notified);
    const fresh = items.filter(item => !seen.has(item.id)).reverse();
    if (fresh.length === 0) return;

    const handled = [];
    for (const item of fresh) {
        const push = ownCheckinNotification(item, kinds);
        if (!push || await send(push.payload, push.collapseID) === "sent") handled.push(item.id);
    }
    if (handled.length > 0) await saveNotified(env, id, [...notified, ...handled]);
}

function saveKnown(env, id, ids) {
    return env.DB.prepare("UPDATE subscriptions SET known = ? WHERE id = ?")
        .bind(JSON.stringify(ids.slice(-REMEMBERED)), id).run();
}

function saveNotified(env, id, ids) {
    return env.DB.prepare("UPDATE subscriptions SET notified = ? WHERE id = ?")
        .bind(JSON.stringify(ids.slice(-REMEMBERED)), id).run();
}

/// The check-ins of others whose ride hasn't ended at `now` and that are on the train or wait for it to
/// leave within `BOARDING_WINDOW` (by plan, so a delay doesn't hide them). Same rule as the app's list
/// (`TraewellingClient.checkedIn`).
export function checkedIn(statuses, me, now) {
    const seen = new Set();
    return statuses.filter(status => {
        if (!Number.isSafeInteger(status?.id) || seen.has(status.id)) return false;
        seen.add(status.id);
        const user = status.user;
        if (!user || user.id === me) return false;
        const { start, end, plannedDeparture } = rideTimes(status.checkin ?? status.train);
        if (start === null || end === null) return false;
        const leaves = Math.min(start, plannedDeparture ?? start);
        return leaves <= now + BOARDING_WINDOW * 1000 && now < end;
    });
}

function rideTimes(checkin) {
    const time = (...values) => {
        for (const value of values) {
            const parsed = typeof value === "string" ? Date.parse(value) : NaN;
            if (!Number.isNaN(parsed)) return parsed;
        }
        return null;
    };
    const origin = checkin?.origin ?? {};
    const destination = checkin?.destination ?? {};
    return {
        start: time(checkin?.manualDeparture, origin.departureReal, origin.departure, origin.departurePlanned),
        end: time(checkin?.manualArrival, destination.arrivalReal, destination.arrival, destination.arrivalPlanned),
        plannedDeparture: time(origin.departurePlanned),
    };
}

/// The notification for someone's check-in: who, and the train from where to where (as the app's
/// `FollowedCheckinNotifier`). Tapping it opens the check-in (`followedStatusID`).
export function notification(status) {
    const checkin = status.checkin ?? status.train ?? {};
    const name = (stop) => stop?.station?.name ?? stop?.name ?? "?";
    const route = `${name(checkin.origin)} → ${name(checkin.destination)}`;
    const line = typeof checkin.lineName === "string" ? checkin.lineName.trim() : "";
    return {
        aps: {
            alert: { title: `${status.user?.displayName ?? "Jemand"} ist eingecheckt`, body: line ? `${line}: ${route}` : route },
            sound: "default",
            "thread-id": "followed-checkins",
        },
        followedStatusID: status.id,
    };
}

/// The push for one of Träwelling's notifications, if it is a like or a fellow traveller and that kind is on.
/// A like opens the user's own check-in (`ownStatusID`), a fellow traveller theirs (`companionStatusID`);
/// that one replaces a followed check-in's push about the same check-in (same collapse ID).
export function ownCheckinNotification(item, kinds) {
    const data = item?.data ?? {};
    const text = (value) => typeof value === "string" ? value.trim() : "";
    const person = (user) => text(user?.name) || (text(user?.username) ? `@${text(user.username)}` : "Jemand");
    const ride = (line, origin, destination) => {
        const route = `${text(origin) || "?"} → ${text(destination) || "?"}`;
        return text(line) ? `${text(line)}: ${route}` : route;
    };
    const statusID = data.status?.id;
    if (!Number.isSafeInteger(statusID)) return null;
    if (item.type === "StatusLiked" && kinds.includes("likes")) {
        const trip = data.trip ?? {};
        return {
            payload: {
                aps: {
                    alert: { title: `${person(data.liker)} gefällt dein Check-in`, body: ride(trip.lineName, trip.origin?.name, trip.destination?.name) },
                    sound: "default",
                    "thread-id": "own-checkins",
                },
                ownStatusID: statusID,
            },
            collapseID: `like-${item.id}`.slice(0, 64),
        };
    }
    if (item.type === "UserJoinedConnection" && kinds.includes("companions")) {
        const checkin = data.checkin ?? {};
        return {
            payload: {
                aps: {
                    alert: { title: `${person(data.user)} fährt mit dir`, body: ride(checkin.linename, checkin.origin, checkin.destination) },
                    sound: "default",
                    "thread-id": "own-checkins",
                },
                companionStatusID: statusID,
            },
            collapseID: `followed-${statusID}`,
        };
    }
    return null;
}

// MARK: - Träwelling

class RejectedGrant extends Error {}
class DeviceGone extends Error {}

function traewelling(path, accessToken, init, fetchUpstream) {
    return fetchUpstream(`${TRAEWELLING}/${path}`, {
        ...init,
        headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json", "User-Agent": USER_AGENT },
    });
}

/// Asks Träwelling's token endpoint; throws `RejectedGrant` when it refuses the code or refresh token.
async function requestTokens(form, now, fetchUpstream) {
    const response = await fetchUpstream(`${TRAEWELLING}/oauth/token`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json", "User-Agent": USER_AGENT },
        body: new URLSearchParams(form).toString(),
    });
    const body = await response.json().catch(() => null);
    if (!response.ok) {
        if ([400, 401].includes(response.status) && ["invalid_grant", "invalid_request", "invalid_client"].includes(body?.error)) {
            throw new RejectedGrant();
        }
        throw new Error(`token endpoint ${response.status}`);
    }
    if (typeof body?.access_token !== "string" || typeof body?.refresh_token !== "string") throw new Error("no token");
    const tokens = {
        access: body.access_token,
        refresh: body.refresh_token,
        expires: Math.floor(now / 1000) + (Number(body.expires_in) > 0 ? Number(body.expires_in) : 3600),
    };
    // Träwelling adds the webhook it made for this login (only when exchanging an authorization code).
    const webhook = body.webhook;
    if (Number.isSafeInteger(webhook?.id) && typeof webhook?.secret === "string" && webhook.secret.length <= 256) {
        tokens.webhook = { id: webhook.id, secret: webhook.secret };
    }
    return tokens;
}

// MARK: - Stored logins

async function tokenKey(base64) {
    return crypto.subtle.importKey("raw", fromBase64(base64), "AES-GCM", false, ["encrypt", "decrypt"]);
}

/// AES-GCM with TOKEN_KEY, bound to the subscription ID; stored as base64(iv ‖ ciphertext).
export async function encryptTokens(tokens, id, keyBase64) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: new TextEncoder().encode(id) },
        await tokenKey(keyBase64), new TextEncoder().encode(JSON.stringify(tokens)));
    const out = new Uint8Array(12 + sealed.byteLength);
    out.set(iv);
    out.set(new Uint8Array(sealed), 12);
    return toBase64(out);
}

export async function decryptTokens(stored, id, keyBase64) {
    const bytes = fromBase64(stored);
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12), additionalData: new TextEncoder().encode(id) },
        await tokenKey(keyBase64), bytes.slice(12));
    return JSON.parse(new TextDecoder().decode(plain));
}

// MARK: - Helpers

function randomHex(bytes) {
    return [...crypto.getRandomValues(new Uint8Array(bytes))].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(text) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

export default {
    fetch(request, env, ctx) {
        return handleRequest(request, env, Date.now(), { waitUntil: promise => ctx.waitUntil(promise) });
    },
    scheduled(event, env, ctx) {
        ctx.waitUntil(processDueSubscriptions(env, event.scheduledTime));
        ctx.waitUntil(processDueCommutes(env, event.scheduledTime));
    },
};
