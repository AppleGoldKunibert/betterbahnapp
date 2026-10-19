// APNs for the `betterbahn-push` Worker: check-in notifications (#266) and regular trips (#397).

import { fromBase64, toBase64 } from "../shared/appattest.mjs";

/// The APNs provider token is reused this long (Apple wants it renewed within an hour, at most every 20 min).
const PROVIDER_TOKEN_TTL = 50 * 60;

/// Sends notifications with a provider token (JWT, ES256) made from the APNs auth key.
export class APNs {
    constructor(env, now, fetchUpstream) {
        this.env = env;
        this.now = now;
        // Called as a plain function: Cloudflare's `fetch` refuses to run as a method of this object.
        this.fetchUpstream = fetchUpstream;
    }

    /// "sent", "gone" (the app was deleted or the token belongs elsewhere) or "failed". A newer notification
    /// with the same `collapseId` replaces the older one on the device.
    async send(subscription, payload, collapseId = `followed-${payload.followedStatusID}`) {
        const host = subscription.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
        const fetchUpstream = this.fetchUpstream;
        const response = await fetchUpstream(`https://${host}/3/device/${subscription.device_token}`, {
            method: "POST",
            headers: {
                authorization: `bearer ${await this.providerToken()}`,
                "apns-topic": this.env.APNS_TOPIC,
                "apns-push-type": "alert",
                "apns-priority": "10",
                "apns-collapse-id": collapseId,
                "content-type": "application/json",
            },
            body: JSON.stringify(payload),
        });
        if (response.ok) return "sent";
        const reason = (await response.json().catch(() => null))?.reason;
        console.log(`APNs ${response.status} ${reason ?? ""}`);
        if (response.status === 410 || ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].includes(reason)) return "gone";
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
