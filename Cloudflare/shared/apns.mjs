// Apple Push Notification service for BetterBahn's Workers (`betterbahn-push`, `betterbahn-live`): sends with a
// provider token (JWT, ES256) made from the APNs auth key and keeps that token in the Worker's D1 `meta` table.

import { fromBase64, toBase64 } from "./appattest.mjs";

/// The provider token is reused this long (Apple wants it renewed within an hour, at most every 20 min).
const PROVIDER_TOKEN_TTL = 50 * 60;

/// Reasons for which the token will never work again: the app was deleted, the token belongs elsewhere,
/// or (for Live Activities) the activity has ended.
const GONE_REASONS = ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered", "ExpiredToken"];

/// `env` holds APNS_KEY (the .p8 file's content), APNS_KEY_ID, APNS_TEAM_ID and the D1 database `DB`.
export class APNs {
    constructor(env, now, fetchUpstream) {
        this.env = env;
        this.now = now;
        // Called as a plain function: Cloudflare's `fetch` refuses to run as a method of this object.
        this.fetchUpstream = fetchUpstream;
    }

    /// Sends `payload` to `token` with `headers` (`apns-topic`, `apns-push-type`, …). "sent", "gone" (the
    /// token will never work again) or "failed".
    async send(token, sandbox, payload, headers) {
        const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
        const fetchUpstream = this.fetchUpstream;
        const response = await fetchUpstream(`https://${host}/3/device/${token}`, {
            method: "POST",
            headers: { authorization: `bearer ${await this.providerToken()}`, "content-type": "application/json", ...headers },
            body: JSON.stringify(payload),
        });
        if (response.ok) return "sent";
        const reason = (await response.json().catch(() => null))?.reason;
        console.log(`APNs ${response.status} ${reason ?? ""}`);
        if (response.status === 410 || GONE_REASONS.includes(reason)) return "gone";
        if (["ExpiredProviderToken", "InvalidProviderToken"].includes(reason)) {
            await this.env.DB.prepare("DELETE FROM meta WHERE key = 'apns_token'").run();
            this.token = null;
        }
        return "failed";
    }

    async providerToken() {
        if (this.token) return this.token;
        const seconds = Math.floor(this.now / 1000);
        const cached = await this.env.DB.prepare("SELECT value, updated FROM meta WHERE key = 'apns_token'").first();
        if (cached && seconds - cached.updated < PROVIDER_TOKEN_TTL) return (this.token = cached.value);
        this.token = await signProviderToken(this.env.APNS_KEY, this.env.APNS_KEY_ID, this.env.APNS_TEAM_ID, seconds);
        await this.env.DB.prepare("INSERT OR REPLACE INTO meta (key, value, updated) VALUES ('apns_token', ?, ?)")
            .bind(this.token, seconds).run();
        return this.token;
    }
}

/// A notification text the app translates on the device: `key` is the German text with `%@` for each of
/// `args`, an entry of the app's `Localizable.xcstrings` (iOS looks it up via `loc-key`).
export const text = (key, ...args) => ({ key, args: args.map(String) });

/// An APNs alert from `text()`s (or plain strings that need no translation). `title` and `body` hold the
/// German text for anything that ignores the keys; iOS shows the device language's version of the keys.
export function localizedAlert(title, body) {
    const alert = { title: german(title), body: german(body) };
    if (typeof title === "object") Object.assign(alert, { "title-loc-key": title.key, "title-loc-args": title.args });
    if (typeof body === "object") Object.assign(alert, { "loc-key": body.key, "loc-args": body.args });
    return alert;
}

function german(value) {
    if (typeof value !== "object") return value;
    let next = 0;
    return value.key.replace(/%@/g, () => value.args[next++] ?? "");
}

export async function signProviderToken(pem, keyId, teamId, issuedAt) {
    const der = fromBase64(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""));
    const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const part = (value) => base64url(new TextEncoder().encode(JSON.stringify(value)));
    const unsigned = `${part({ alg: "ES256", kid: keyId })}.${part({ iss: teamId, iat: issuedAt })}`;
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
    return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

function base64url(bytes) {
    return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
