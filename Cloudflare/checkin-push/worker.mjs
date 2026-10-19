// Worker `betterbahn-push`: push notifications for new check-ins of the people a Träwelling user follows
// (#266), so they arrive even while iOS doesn't let the app look itself.
//
// Turning them on in the app signs in with Träwelling a second time, for this Worker only and with the
// read-only scope `read-statuses`: the app sends the authorization code here and the Worker keeps that
// login (encrypted), never the app's own. Träwelling's access tokens last an hour and each refresh token
// works once, so sharing the app's login would log one of the two out.
//
// Every minute the cron trigger looks at the subscriptions due in that minute: Träwelling's dashboard,
// then an APNs notification for each check-in that is new since the last look. The first look only
// remembers what runs already.
//
// It also looks after the journeys of regular trips (#397, `/commutes`, see commute.mjs).

import { APNs } from "../shared/apns.mjs";
import { TOKEN_HEADER, fromBase64, toBase64, unauthorized, verifyToken } from "../shared/appattest.mjs";
import { handleCommute, processDueCommutes } from "./commute.mjs";

export { signProviderToken } from "../shared/apns.mjs";

const TRAEWELLING = "https://traewelling.de";
const USER_AGENT = "BetterBahn-Push (+https://betterbahn.betterbahn.workers.dev/support)";
export const SCOPE = "read-statuses";
const MINUTE = 60;
/// How many status IDs are remembered: far more than the people followed are ever checked in at once.
const REMEMBERED = 200;
/// Rides that leave within this time (by plan) already count as checked in, as in the app.
const BOARDING_WINDOW = 20 * MINUTE;
const DEVICE_TOKEN_PATTERN = /^[0-9a-f]{64,200}$/;
const ID_PATTERN = /^[0-9a-f]{32}$/;
const MAX_BODY_BYTES = 16 * 1024;

// MARK: - HTTP

/// POST   /subscriptions      { code, codeVerifier, deviceToken, sandbox, userId } → 201 { id, secret }
/// PUT    /subscriptions/<id> { secret, deviceToken, sandbox }                     → 200 {} (404: gone)
/// DELETE /subscriptions/<id> { secret }                                            → 204
/// PUT    /commutes/<id>      { secret, deviceToken, sandbox, journeys }            → 200 { watched } (see commute.mjs)
export async function handleRequest(request, env = {}, now = Date.now(), deps = {}) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json(200, { ok: true });
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
    const row = await env.DB.prepare("SELECT id, secret_hash, tokens FROM subscriptions WHERE id = ?").bind(id).first();
    if (!row || typeof body.secret !== "string" || await sha256Hex(body.secret) !== row.secret_hash) {
        return json(404, { error: "not_found" });
    }
    if (request.method === "PUT") {
        if (!isDeviceToken(body.deviceToken)) return json(400, { error: "invalid_device_token" });
        await env.DB.prepare("UPDATE subscriptions SET device_token = ?, sandbox = ? WHERE id = ?")
            .bind(body.deviceToken, body.sandbox ? 1 : 0, id).run();
        return json(200, {});
    }
    if (request.method === "DELETE") {
        await env.DB.prepare("DELETE FROM subscriptions WHERE id = ?").bind(id).run();
        // Ends the Worker's Träwelling login too; nothing is lost when that fails, the token expires within the hour.
        const tokens = await decryptTokens(row.tokens, id, env.TOKEN_KEY).catch(() => null);
        if (tokens) await traewelling("api/v1/auth/logout", tokens.access, { method: "POST" }, deps.fetch ?? fetch).catch(() => {});
        return new Response(null, { status: 204 });
    }
    return json(405, { error: "method_not_allowed" }, { Allow: "PUT, DELETE" });
}

async function subscribe(body, env, now, fetchUpstream) {
    const { code, codeVerifier, deviceToken, sandbox, userId } = body;
    if (typeof code !== "string" || !code || code.length > 2048 || typeof codeVerifier !== "string"
        || !/^[A-Za-z0-9._~-]{43,128}$/.test(codeVerifier)) {
        return json(400, { error: "invalid_code" });
    }
    if (!isDeviceToken(deviceToken)) return json(400, { error: "invalid_device_token" });
    if (!Number.isSafeInteger(userId) || userId <= 0) return json(400, { error: "invalid_user" });

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
    await env.DB.prepare(
        "INSERT INTO subscriptions (id, secret_hash, device_token, sandbox, user_id, tokens, known, slot, created) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)",
    ).bind(id, await sha256Hex(secret), deviceToken, sandbox ? 1 : 0, userId, await encryptTokens(tokens, id, env.TOKEN_KEY), slot, Math.floor(now / 1000)).run();
    return json(201, { id, secret });
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
        "SELECT id, device_token, sandbox, user_id, tokens, known FROM subscriptions WHERE slot % ? = ?",
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

/// One look for one subscription. Writes only when something changed (a refreshed login, new check-ins).
async function check(subscription, env, now, fetchUpstream, apns) {
    const { id } = subscription;
    const remove = () => env.DB.prepare("DELETE FROM subscriptions WHERE id = ?").bind(id).run();
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

    let page;
    try {
        if (tokens.expires <= now / 1000 + MINUTE) await refresh();
        let response = await traewelling("api/v1/dashboard", tokens.access, {}, fetchUpstream);
        if (response.status === 401 && !refreshed) {
            await refresh();
            response = await traewelling("api/v1/dashboard", tokens.access, {}, fetchUpstream);
        }
        if (response.status === 401) throw new RejectedGrant();
        if (!response.ok) return;
        page = await response.json();
    } catch (error) {
        // The login ended (revoked on Träwelling, unused too long): the app learns it from a 404 and
        // turns the setting off.
        if (error instanceof RejectedGrant) await remove();
        return;
    }

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
        const result = await apns.send(subscription.device_token, subscription.sandbox, payload, {
            "apns-topic": env.APNS_TOPIC,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": `followed-${payload.followedStatusID}`,
        });
        if (result === "gone") {
            await remove();
            return;
        }
        if (result === "sent") sent.push(status.id);
    }
    if (sent.length > 0) await saveKnown(env, id, [...known, ...sent]);
}

function saveKnown(env, id, ids) {
    return env.DB.prepare("UPDATE subscriptions SET known = ? WHERE id = ?")
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

// MARK: - Träwelling

class RejectedGrant extends Error {}

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
    return {
        access: body.access_token,
        refresh: body.refresh_token,
        expires: Math.floor(now / 1000) + (Number(body.expires_in) > 0 ? Number(body.expires_in) : 3600),
    };
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
    fetch(request, env) {
        return handleRequest(request, env);
    },
    scheduled(event, env, ctx) {
        ctx.waitUntil(processDueSubscriptions(env, event.scheduledTime));
        ctx.waitUntil(processDueCommutes(env, event.scheduledTime));
    },
};
