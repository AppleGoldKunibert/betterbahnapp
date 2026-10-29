// The app's Träwelling login, kept by this Worker (#452).
//
// Träwelling's access tokens last an hour, refresh tokens 30 days, and each refresh token works once. A
// device renewing its own login lost it when the answer to a renewal didn't arrive (poor reception: the old
// refresh token is gone, the new one never came) or after 30 days without opening the app. Now this Worker
// holds the only login per user and is the only one renewing it; the app just fetches the current access
// token, which changes nothing here, so a lost answer costs nothing.
//
// POST   /logins              { code, codeVerifier } | { refreshToken } → 201 { id, secret, accessToken, expiresAt, readsNotifications }
// PUT    /logins/<id>         { secret, code, codeVerifier }           → 200 { accessToken, expiresAt, readsNotifications }
// POST   /logins/<id>/token   { secret, rejected? }                    → 200 { accessToken, expiresAt, readsNotifications }
// DELETE /logins/<id>         { secret }                               → 204
//
// A new login sends the authorization code with its PKCE verifier; apps from before #452 hand over their
// refresh token once instead, which is renewed at once and then only known here. PUT signs in again in
// place (a login from before #452 can't read Träwelling's notifications), so `id` and `secret` stay the
// same. `rejected` is the access token Träwelling just refused: it is renewed even if it should still work.
// 404 means the login has ended (logged out, revoked on Träwelling): the app signs in again.
//
// Renewed when less than `RENEW_BEFORE` is left, and saved before answering. Only one request renews at a
// time (`renewing` holds it for `LEASE` seconds); the others wait for its new tokens. The cron trigger
// renews logins nobody renewed for `IDLE_RENEWAL` and ends those no device fetched for `UNUSED` days.
//
// A login made while the Worker offers a webhook (`/login-options`) brings Träwelling's webhook for the user's
// notifications; its secret is kept sealed with the login, and `/traewelling/webhook` (worker.mjs) pushes to
// every sign-up on the login.

import { fromBase64, toBase64 } from "../shared/appattest.mjs";

export const TRAEWELLING = "https://traewelling.de";
const USER_AGENT = "BetterBahn-Push (+https://betterbahn.betterbahn.workers.dev/support)";
const MINUTE = 60;
const DAY = 24 * 3600;
/// Renewed when less is left: the app fetches the next one from 10 minutes before the end.
export const RENEW_BEFORE = 15 * MINUTE;
/// How long one request may take to renew before another may try.
const LEASE = 30;
/// Renewed at the latest after this, so a login no one uses doesn't run out (refresh tokens last 30 days).
export const IDLE_RENEWAL = 20 * DAY;
/// Ended when no device fetched a token for this long (and no notifications run on it): the app was
/// deleted without logging out.
export const UNUSED = 180 * DAY;
/// Logins renewed or ended per cron run, well below the 50 outgoing requests an invocation may make.
const PER_RUN = 5;
const ID_PATTERN = /^[0-9a-f]{32}$/;

export class RejectedGrant extends Error {}
/// The login no longer exists (ended here or by Träwelling).
export class LoginEnded extends Error {}
/// Another request is renewing and didn't finish in time.
export class LoginBusy extends Error {}

// MARK: - HTTP

export async function handleLogin(path, method, body, env, now, deps = {}) {
    const fetchUpstream = deps.fetch ?? fetch;
    const [, id, action] = path.match(/^\/logins(?:\/([^/]+)(?:\/(token))?)?$/) ?? [];
    if (!id) {
        if (method !== "POST") return json(405, { error: "method_not_allowed" }, { Allow: "POST" });
        return createLogin(body, env, now, fetchUpstream);
    }
    if (!ID_PATTERN.test(id)) return json(404, { error: "not_found" });
    const row = await verifiedLogin(env, id, body.secret);
    if (!row) return json(404, { error: "not_found" });

    if (action === "token") {
        if (method !== "POST") return json(405, { error: "method_not_allowed" }, { Allow: "POST" });
        try {
            const tokens = await currentTokens(env, id, now, fetchUpstream, {
                rejected: typeof body.rejected === "string" ? body.rejected : undefined,
                sleep: deps.sleep,
            });
            await env.DB.prepare("UPDATE logins SET used = ? WHERE id = ?").bind(seconds(now), id).run();
            return json(200, answer(tokens, row.notifications));
        } catch (error) {
            return failure(error);
        }
    }
    if (method === "PUT") return signInAgain(id, body, env, now, fetchUpstream);
    if (method === "DELETE") {
        await endLogin(env, id);
        // Ends the webhook and the Träwelling login too; nothing is lost when that fails: it is forgotten here, and
        // the webhook's next delivery gets a 410, on which Träwelling deletes it.
        const tokens = await decryptTokens(row.tokens, loginAAD(id), env.TOKEN_KEY).catch(() => null);
        if (tokens) await endAtTraewelling(tokens, row.webhook_id, fetchUpstream);
        return new Response(null, { status: 204 });
    }
    return json(405, { error: "method_not_allowed" }, { Allow: "PUT, DELETE" });
}

async function createLogin(body, env, now, fetchUpstream) {
    let tokens;
    const byCode = body.refreshToken === undefined;
    try {
        if (byCode) {
            const form = codeForm(body, env);
            if (!form) return json(400, { error: "invalid_code" });
            tokens = await requestTokens(form, now, fetchUpstream);
        } else {
            if (typeof body.refreshToken !== "string" || !body.refreshToken || body.refreshToken.length > 4096) {
                return json(400, { error: "invalid_grant" });
            }
            // Renewed at once: from now on only this Worker knows a working refresh token.
            tokens = await requestTokens(refreshForm(body.refreshToken, env), now, fetchUpstream);
        }
    } catch (error) {
        if (error instanceof RejectedGrant) return json(400, { error: byCode ? "invalid_code" : "invalid_grant" });
        return json(502, { error: "traewelling_unavailable" });
    }

    const id = randomHex(16);
    const secret = randomHex(32);
    // A login made with the app's scopes since #452 can read Träwelling's notifications; one handed over can't.
    const notifications = byCode ? 1 : 0;
    const { webhook = null, ...login } = tokens;
    await env.DB.prepare(
        "INSERT INTO logins (id, secret_hash, tokens, notifications, renewed, renewing, used, webhook_id, webhook, created) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)",
    ).bind(id, await sha256Hex(secret), await encryptTokens(login, loginAAD(id), env.TOKEN_KEY), notifications,
        seconds(now), seconds(now), webhook?.id ?? null, await sealedWebhook(webhook, id, env), seconds(now)).run();
    return json(201, { id, secret, ...answer(login, notifications) });
}

/// Signs in again in place, with the app's current scopes. The old Träwelling login is ended.
async function signInAgain(id, body, env, now, fetchUpstream) {
    const form = codeForm(body, env);
    if (!form) return json(400, { error: "invalid_code" });
    let tokens;
    try {
        tokens = await requestTokens(form, now, fetchUpstream);
    } catch (error) {
        return json(error instanceof RejectedGrant ? 400 : 502, { error: error instanceof RejectedGrant ? "invalid_code" : "traewelling_unavailable" });
    }
    const row = await env.DB.prepare("SELECT tokens, webhook_id FROM logins WHERE id = ?").bind(id).first();
    const { webhook = null, ...login } = tokens;
    await env.DB.prepare(
        "UPDATE logins SET tokens = ?, notifications = 1, renewed = ?, renewing = NULL, used = ?, webhook_id = ?, webhook = ? WHERE id = ?",
    ).bind(await encryptTokens(login, loginAAD(id), env.TOKEN_KEY), seconds(now), seconds(now), webhook?.id ?? null,
        await sealedWebhook(webhook, id, env), id).run();
    const old = row ? await decryptTokens(row.tokens, loginAAD(id), env.TOKEN_KEY).catch(() => null) : null;
    if (old) await endAtTraewelling(old, row.webhook_id, fetchUpstream);
    return json(200, answer(login, 1));
}

/// The webhook's secret, sealed like the tokens; null without a webhook.
async function sealedWebhook(webhook, id, env) {
    return webhook ? encryptTokens({ secret: webhook.secret }, loginAAD(id), env.TOKEN_KEY) : null;
}

/// Deletes the login's webhook and logs out at Träwelling; failures are ignored.
async function endAtTraewelling(tokens, webhookID, fetchUpstream) {
    if (Number.isSafeInteger(webhookID)) {
        await traewelling(`api/v1/webhooks/${webhookID}`, tokens.access, { method: "DELETE" }, fetchUpstream).catch(() => {});
    }
    await traewelling("api/v1/auth/logout", tokens.access, { method: "POST" }, fetchUpstream).catch(() => {});
}

function codeForm(body, env) {
    const { code, codeVerifier } = body;
    if (typeof code !== "string" || !code || code.length > 2048 || typeof codeVerifier !== "string"
        || !/^[A-Za-z0-9._~-]{43,128}$/.test(codeVerifier)) return null;
    return {
        grant_type: "authorization_code",
        client_id: env.TRAEWELLING_CLIENT_ID ?? "406",
        redirect_uri: env.TRAEWELLING_REDIRECT_URI ?? "",
        code_verifier: codeVerifier,
        code,
    };
}

function refreshForm(refreshToken, env) {
    // No `scope`: the new token keeps what the login granted.
    return { grant_type: "refresh_token", client_id: env.TRAEWELLING_CLIENT_ID ?? "406", refresh_token: refreshToken };
}

function answer(tokens, notifications) {
    return { accessToken: tokens.access, expiresAt: tokens.expires, readsNotifications: notifications === 1 };
}

function failure(error) {
    if (error instanceof LoginEnded) return json(404, { error: "not_found" });
    if (error instanceof LoginBusy) return json(503, { error: "busy" }, { "Retry-After": "2" });
    return json(502, { error: "traewelling_unavailable" });
}

/// The login with this ID if `secret` is its secret.
export async function verifiedLogin(env, id, secret) {
    if (typeof id !== "string" || !ID_PATTERN.test(id) || typeof secret !== "string") return null;
    const row = await env.DB.prepare("SELECT id, secret_hash, tokens, notifications, webhook_id FROM logins WHERE id = ?").bind(id).first();
    return row && await sha256Hex(secret) === row.secret_hash ? row : null;
}

/// Forgets the login and the notifications running on it.
async function endLogin(env, id) {
    await env.DB.prepare("DELETE FROM subscriptions WHERE login_id = ?").bind(id).run();
    await env.DB.prepare("DELETE FROM logins WHERE id = ?").bind(id).run();
}

// MARK: - Tokens

/// The login's tokens, renewed first when less than `renewBefore` seconds are left, `rejected` is the
/// current access token or `force` is set. Throws `LoginEnded` when Träwelling refuses the renewal (the
/// login is deleted then), `LoginBusy` when another request renews and doesn't finish in time.
export async function currentTokens(env, id, now, fetchUpstream, { renewBefore = RENEW_BEFORE, rejected, force = false, sleep } = {}) {
    const row = await env.DB.prepare("SELECT tokens, renewing FROM logins WHERE id = ?").bind(id).first();
    if (!row) throw new LoginEnded();
    const tokens = await decryptTokens(row.tokens, loginAAD(id), env.TOKEN_KEY);
    const due = force || tokens.expires - seconds(now) < renewBefore || (rejected !== undefined && rejected === tokens.access);
    if (!due) return tokens;

    // Only one request renews: the refresh token works once, a second renewal with it would end the login.
    const claim = await env.DB.prepare(
        "UPDATE logins SET renewing = ? WHERE id = ? AND tokens = ? AND (renewing IS NULL OR renewing < ?)",
    ).bind(seconds(now) + LEASE, id, row.tokens, seconds(now)).run();
    if (!claim.meta?.changes) return awaitRenewal(env, id, row.tokens, tokens, now, rejected, sleep);

    let fresh;
    try {
        fresh = await requestTokens(refreshForm(tokens.refresh, env), now, fetchUpstream);
    } catch (error) {
        if (error instanceof RejectedGrant) {
            await endLogin(env, id);
            throw new LoginEnded();
        }
        await env.DB.prepare("UPDATE logins SET renewing = NULL WHERE id = ?").bind(id).run();
        throw error;
    }
    // Saved at once: the old refresh token no longer works.
    await env.DB.prepare("UPDATE logins SET tokens = ?, renewed = ?, renewing = NULL WHERE id = ?")
        .bind(await encryptTokens(fresh, loginAAD(id), env.TOKEN_KEY), seconds(now), id).run();
    return fresh;
}

/// Waits up to about 10 seconds for the request renewing meanwhile. Until then the current access token
/// still works, unless Träwelling just refused it.
async function awaitRenewal(env, id, stored, tokens, now, rejected, sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms))) {
    for (let attempt = 0; attempt < 20; attempt++) {
        const row = await env.DB.prepare("SELECT tokens FROM logins WHERE id = ?").bind(id).first();
        if (!row) throw new LoginEnded();
        if (row.tokens !== stored) return decryptTokens(row.tokens, loginAAD(id), env.TOKEN_KEY);
        if (attempt === 0 && tokens.expires > seconds(now) + MINUTE && rejected !== tokens.access) return tokens;
        await sleep(500);
    }
    throw new LoginBusy();
}

// MARK: - Cron

/// Renews logins nobody renewed for `IDLE_RENEWAL` and ends those no device fetched a token from for
/// `UNUSED`, a few per run.
export async function maintainLogins(env, now = Date.now(), deps = {}) {
    const fetchUpstream = deps.fetch ?? fetch;
    const { results: unused } = await env.DB.prepare(
        "SELECT id FROM logins WHERE used < ? AND id NOT IN (SELECT login_id FROM subscriptions WHERE login_id IS NOT NULL) LIMIT ?",
    ).bind(seconds(now) - UNUSED, PER_RUN).all();
    for (const { id } of unused ?? []) await endLogin(env, id);

    const { results: idle } = await env.DB.prepare("SELECT id FROM logins WHERE renewed < ? LIMIT ?")
        .bind(seconds(now) - IDLE_RENEWAL, PER_RUN).all();
    for (const { id } of idle ?? []) {
        try {
            await currentTokens(env, id, now, fetchUpstream, { force: true, sleep: deps.sleep });
        } catch (error) {
            // Träwelling unreachable: the next run tries again.
            if (!(error instanceof LoginEnded)) console.log(`renewal failed: ${error?.message ?? error}`);
        }
    }
}

// MARK: - Träwelling

export function traewelling(path, accessToken, init, fetchUpstream) {
    return fetchUpstream(`${TRAEWELLING}/${path}`, {
        ...init,
        headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json", "User-Agent": USER_AGENT },
    });
}

/// Asks Träwelling's token endpoint; throws `RejectedGrant` when it refuses the code or refresh token.
export async function requestTokens(form, now, fetchUpstream) {
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
        expires: seconds(now) + (Number(body.expires_in) > 0 ? Number(body.expires_in) : 3600),
    };
    // Träwelling adds the webhook it made for this login (only when exchanging an authorization code). Callers
    // keep it apart from the tokens.
    const webhook = body.webhook;
    if (Number.isSafeInteger(webhook?.id) && typeof webhook?.secret === "string" && webhook.secret.length <= 256) {
        tokens.webhook = { id: webhook.id, secret: webhook.secret };
    }
    return tokens;
}

// MARK: - Stored logins

/// What a login's tokens are bound to, apart from the subscriptions' own logins from before #452.
export function loginAAD(id) {
    return `login:${id}`;
}

async function tokenKey(base64) {
    return crypto.subtle.importKey("raw", fromBase64(base64), "AES-GCM", false, ["encrypt", "decrypt"]);
}

/// AES-GCM with TOKEN_KEY, bound to `aad` (the row's ID); stored as base64(iv ‖ ciphertext).
export async function encryptTokens(tokens, aad, keyBase64) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: new TextEncoder().encode(aad) },
        await tokenKey(keyBase64), new TextEncoder().encode(JSON.stringify(tokens)));
    const out = new Uint8Array(12 + sealed.byteLength);
    out.set(iv);
    out.set(new Uint8Array(sealed), 12);
    return toBase64(out);
}

export async function decryptTokens(stored, aad, keyBase64) {
    const bytes = fromBase64(stored);
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12), additionalData: new TextEncoder().encode(aad) },
        await tokenKey(keyBase64), bytes.slice(12));
    return JSON.parse(new TextDecoder().decode(plain));
}

// MARK: - Helpers

function seconds(now) {
    return Math.floor(now / 1000);
}

export function randomHex(bytes) {
    return [...crypto.getRandomValues(new Uint8Array(bytes))].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(text) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

export function json(status, body, headers = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
    });
}
