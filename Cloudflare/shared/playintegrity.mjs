// Play Integrity for BetterBahn's Workers: the Android app's counterpart to App Attest (./appattest.mjs). The app asks
// Google Play for an integrity token over a challenge from `/auth/challenge`; Google decodes it for us and says whether
// it comes from our app as installed from Google Play on a genuine device. Then the app gets the same access token as
// after App Attest.
//
// POST /auth/play { integrityToken, challenge } → { token, expiresIn }
//
// The app sends `requestHash` = hex SHA-256 of the challenge. Configuration: secret PLAY_INTEGRITY_KEY (the Google
// Cloud service account's JSON key, from the project linked to the app in the Play Console), var PLAY_PACKAGE (default
// de.goldkunibert.betterbahn). PLAY_INTEGRITY_ALLOW_TESTING = "true" also accepts builds not installed from Google Play
// and devices that fail the device check (emulator, sideloaded debug build); for testing only.

export const PLAY_PACKAGE = "de.goldkunibert.betterbahn";
/// How old an integrity token may be.
export const MAX_TOKEN_AGE = 5 * 60 * 1000;
const SCOPE = "https://www.googleapis.com/auth/playintegrity";
const OAUTH_URL = "https://oauth2.googleapis.com/token";

/// Why a decoded token isn't accepted, or null when it is.
export function rejection(payload, { packageName, requestHash, now, allowTesting = false }) {
    const request = payload?.requestDetails ?? {};
    if (request.requestPackageName !== packageName) return "package";
    if (request.requestHash !== requestHash) return "request_hash";
    const timestamp = Number(request.timestampMillis);
    if (!Number.isFinite(timestamp) || Math.abs(now - timestamp) > MAX_TOKEN_AGE) return "stale";
    if (allowTesting) return null;
    const app = payload.appIntegrity ?? {};
    if (app.appRecognitionVerdict !== "PLAY_RECOGNIZED" || app.packageName !== packageName) return "app";
    const device = payload.deviceIntegrity?.deviceRecognitionVerdict ?? [];
    if (!device.includes("MEETS_DEVICE_INTEGRITY")) return "device";
    return null;
}

/// Checks a Play Integrity token over `challenge` with Google; throws with the reason if it isn't accepted.
export async function verifyPlayIntegrity({ integrityToken, challenge, env, now = Date.now(), fetchImpl = fetch }) {
    if (typeof integrityToken !== "string" || integrityToken.length > 16 * 1024) throw new Error("input");
    const packageName = env.PLAY_PACKAGE || PLAY_PACKAGE;
    const accessToken = await googleAccessToken(JSON.parse(env.PLAY_INTEGRITY_KEY), now, fetchImpl);
    const response = await fetchImpl(`https://playintegrity.googleapis.com/v1/${packageName}:decodeIntegrityToken`, {
        method: "POST",
        headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ integrity_token: integrityToken }),
    });
    if (!response.ok) throw new Error(`decode ${response.status}`);
    const { tokenPayloadExternal } = await response.json();
    const reason = rejection(tokenPayloadExternal, {
        packageName, requestHash: await sha256Hex(challenge), now, allowTesting: env.PLAY_INTEGRITY_ALLOW_TESTING === "true",
    });
    if (reason) throw new Error(reason);
}

// MARK: - Google service account

let cachedAccess = null;

/// An OAuth access token for the service account (a JWT signed with its key, exchanged at Google), kept until shortly
/// before it expires.
async function googleAccessToken(key, now, fetchImpl) {
    if (cachedAccess && cachedAccess.email === key.client_email && cachedAccess.expires > now + 60_000) return cachedAccess.token;
    const issued = Math.floor(now / 1000);
    const assertion = await signJWT({ iss: key.client_email, scope: SCOPE, aud: OAUTH_URL, iat: issued, exp: issued + 3600 },
        key.private_key);
    const response = await fetchImpl(OAUTH_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }).toString(),
    });
    if (!response.ok) throw new Error(`oauth ${response.status}`);
    const { access_token: token, expires_in: expiresIn } = await response.json();
    cachedAccess = { email: key.client_email, token, expires: now + (Number(expiresIn) || 3600) * 1000 };
    return token;
}

/// For tests: forget the cached access token.
export function resetAccessTokenCache() {
    cachedAccess = null;
}

async function signJWT(claims, privateKeyPEM) {
    const encode = value => base64url(new TextEncoder().encode(JSON.stringify(value)));
    const unsigned = `${encode({ alg: "RS256", typ: "JWT" })}.${encode(claims)}`;
    const der = Uint8Array.from(atob(privateKeyPEM.replace(/-----[^-]+-----|\s/g, "")), c => c.charCodeAt(0));
    const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
    return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

export async function sha256Hex(text) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
    return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}

function base64url(bytes) {
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
