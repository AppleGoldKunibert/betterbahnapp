import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";
import { handleAuth, verifyToken } from "./appattest.mjs";
import { PLAY_PACKAGE, rejection, resetAccessTokenCache, sha256Hex } from "./playintegrity.mjs";

const SECRET = "test-secret";
const NOW = Date.UTC(2026, 9, 29, 12);
const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const KEY = JSON.stringify({
    client_email: "play@example.iam.gserviceaccount.com",
    private_key: privateKey.export({ type: "pkcs8", format: "pem" }),
});
const ENV = { TOKEN_SECRET: SECRET, APP_IDS: "TEAMID1234.de.goldkunibert.BetterBahn", PLAY_INTEGRITY_KEY: KEY };

function verdict(requestHash, overrides = {}) {
    return {
        requestDetails: { requestPackageName: PLAY_PACKAGE, requestHash, timestampMillis: String(NOW - 1000) },
        appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED", packageName: PLAY_PACKAGE },
        deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_DEVICE_INTEGRITY"] },
        ...overrides,
    };
}

/// Google's OAuth and decode endpoints, answering with `payload(requestHash)`; records the requests.
function fakeGoogle(payload) {
    const calls = [];
    const fetchImpl = async (url, init) => {
        calls.push({ url, init });
        if (url === "https://oauth2.googleapis.com/token") {
            return Response.json({ access_token: "google-access", expires_in: 3600 });
        }
        assert.equal(init.headers.Authorization, "Bearer google-access");
        return Response.json({ tokenPayloadExternal: payload });
    };
    return { fetchImpl, calls };
}

async function challenge(env = ENV) {
    const response = await handleAuth(new Request("https://w.example/auth/challenge"), env, NOW);
    return (await response.json()).challenge;
}

const play = (body, env = ENV, fetchImpl) => handleAuth(new Request("https://w.example/auth/play", {
    method: "POST", body: JSON.stringify(body),
}), env, NOW, fetchImpl);

test("a genuine Play install gets an access token", async () => {
    resetAccessTokenCache();
    const c = await challenge();
    const google = fakeGoogle(verdict(await sha256Hex(c)));
    const response = await play({ integrityToken: "opaque", challenge: c }, ENV, google.fetchImpl);
    assert.equal(response.status, 200);
    const { token, expiresIn } = await response.json();
    assert.equal(expiresIn, 3600);
    assert.match((await verifyToken(token, "a", SECRET, NOW)).kid, /^play:[\w-]{22}$/);
    assert.equal(google.calls[1].url, `https://playintegrity.googleapis.com/v1/${PLAY_PACKAGE}:decodeIntegrityToken`);
    assert.deepEqual(JSON.parse(google.calls[1].init.body), { integrity_token: "opaque" });
    // The service account signs an RS256 JWT for Google's OAuth.
    const assertion = new URLSearchParams(google.calls[0].init.body).get("assertion");
    const claims = JSON.parse(Buffer.from(assertion.split(".")[1], "base64url"));
    assert.equal(claims.iss, "play@example.iam.gserviceaccount.com");
    assert.equal(claims.scope, "https://www.googleapis.com/auth/playintegrity");
});

test("the Google access token is reused", async () => {
    resetAccessTokenCache();
    for (let i = 0; i < 2; i++) {
        const c = await challenge();
        const google = fakeGoogle(verdict(await sha256Hex(c)));
        assert.equal((await play({ integrityToken: "opaque", challenge: c }, ENV, google.fetchImpl)).status, 200);
        assert.equal(google.calls.length, i === 0 ? 2 : 1);
    }
});

test("a token over another challenge is refused", async () => {
    resetAccessTokenCache();
    const c = await challenge();
    const google = fakeGoogle(verdict(await sha256Hex("something else")));
    const response = await play({ integrityToken: "opaque", challenge: c }, ENV, google.fetchImpl);
    assert.equal(response.status, 403);
});

test("without our challenge Google isn't asked", async () => {
    const google = fakeGoogle(verdict("x"));
    const response = await play({ integrityToken: "opaque", challenge: "forged" }, ENV, google.fetchImpl);
    assert.equal(response.status, 400);
    assert.equal(google.calls.length, 0);
});

test("without the service account key the route isn't available", async () => {
    const env = { ...ENV, PLAY_INTEGRITY_KEY: undefined };
    const response = await play({ integrityToken: "opaque", challenge: await challenge(env) }, env, fakeGoogle({}).fetchImpl);
    assert.equal(response.status, 503);
});

test("verdicts", async () => {
    const hash = await sha256Hex("c");
    const options = { packageName: PLAY_PACKAGE, requestHash: hash, now: NOW };
    assert.equal(rejection(verdict(hash), options), null);
    assert.equal(rejection(verdict(hash), { ...options, packageName: "other.app" }), "package");
    assert.equal(rejection(verdict(hash), { ...options, now: NOW + 10 * 60 * 1000 }), "stale");
    const sideloaded = verdict(hash, { appIntegrity: { appRecognitionVerdict: "UNRECOGNIZED_VERSION" } });
    assert.equal(rejection(sideloaded, options), "app");
    const emulator = verdict(hash, { deviceIntegrity: {} });
    assert.equal(rejection(emulator, options), "device");
    // For testing: emulator and sideloaded builds are fine, the request itself is still checked.
    assert.equal(rejection(emulator, { ...options, allowTesting: true }), null);
    assert.equal(rejection(sideloaded, { ...options, allowTesting: true }), null);
    assert.equal(rejection(verdict("other"), { ...options, allowTesting: true }), "request_hash");
    assert.equal(rejection(undefined, options), "package");
});
