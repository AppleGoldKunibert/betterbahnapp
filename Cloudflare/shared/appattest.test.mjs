import assert from "node:assert/strict";
import test from "node:test";
import {
    APPLE_ROOT_PEM, TOKEN_HEADER, decodeCBOR, derSignatureToRaw, fromBase64, handleAuth, isAuthorized, isSignedBy,
    parseCertificate, signToken, toBase64, verifyAssertion, verifyAttestation, verifyToken,
} from "./appattest.mjs";

const APP_ID = "TEAMID1234.de.goldkunibert.BetterBahn";
const SECRET = "test-secret";
const encoder = new TextEncoder();

// MARK: - Test helpers: DER, CBOR and a fake App Attest chain

function concat(...parts) {
    const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
    let position = 0;
    for (const part of parts) {
        out.set(part, position);
        position += part.length;
    }
    return out;
}

function lengthBytes(length) {
    if (length < 0x80) return Uint8Array.of(length);
    const bytes = [];
    for (let value = length; value > 0; value = Math.floor(value / 256)) bytes.unshift(value & 0xff);
    return Uint8Array.of(0x80 | bytes.length, ...bytes);
}

const der = (tag, ...parts) => {
    const content = concat(...parts);
    return concat(Uint8Array.of(tag), lengthBytes(content.length), content);
};
const sequence = (...parts) => der(0x30, ...parts);
const integer = value => der(0x02, Uint8Array.of(value));
const octets = bytes => der(0x04, bytes);
const bitString = bytes => der(0x03, Uint8Array.of(0), bytes);
const boolean = value => der(0x01, Uint8Array.of(value ? 0xff : 0));
const generalizedTime = date => der(0x18, encoder.encode(date.toISOString().replace(/[-:T]/g, "").slice(0, 14) + "Z"));
const name = commonName => sequence(der(0x31, sequence(oid("2.5.4.3"), der(0x0c, encoder.encode(commonName)))));

function oid(text) {
    const [first, second, ...rest] = text.split(".").map(Number);
    const bytes = [first * 40 + second];
    for (const part of rest) {
        const groups = [];
        let value = part;
        do {
            groups.unshift(value & 0x7f);
            value = Math.floor(value / 128);
        } while (value > 0);
        bytes.push(...groups.map((group, index) => (index < groups.length - 1 ? group | 0x80 : group)));
    }
    return der(0x06, Uint8Array.from(bytes));
}

function rawToDERSignature(raw) {
    const half = raw.length / 2;
    const toInteger = bytes => {
        let start = 0;
        while (start < bytes.length - 1 && bytes[start] === 0) start++;
        const trimmed = bytes.subarray(start);
        return der(0x02, trimmed[0] & 0x80 ? concat(Uint8Array.of(0), trimmed) : trimmed);
    };
    return sequence(toInteger(raw.subarray(0, half)), toInteger(raw.subarray(half)));
}

async function makeCertificate({ subject, issuer, publicKey, signingKey, hash, ca = false, extensions = [], notAfter }) {
    const algorithm = hash === "SHA-384" ? "1.2.840.10045.4.3.3" : "1.2.840.10045.4.3.2";
    const spki = new Uint8Array(await crypto.subtle.exportKey("spki", publicKey));
    const allExtensions = [...extensions];
    if (ca) allExtensions.push(sequence(oid("2.5.29.19"), boolean(true), octets(sequence(boolean(true)))));
    const tbs = sequence(
        der(0xa0, integer(2)), integer(1), sequence(oid(algorithm)), name(issuer),
        sequence(generalizedTime(new Date("2020-01-01T00:00:00Z")), generalizedTime(notAfter ?? new Date("2040-01-01T00:00:00Z"))),
        name(subject), spki,
        ...(allExtensions.length ? [der(0xa3, sequence(...allExtensions))] : []),
    );
    const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash }, signingKey, tbs));
    return sequence(tbs, sequence(oid(algorithm)), bitString(rawToDERSignature(signature)));
}

function encodeCBOR(value) {
    const head = (major, length) => {
        if (length < 24) return Uint8Array.of((major << 5) | length);
        if (length < 256) return Uint8Array.of((major << 5) | 24, length);
        return Uint8Array.of((major << 5) | 25, length >> 8, length & 0xff);
    };
    if (value instanceof Uint8Array) return concat(head(2, value.length), value);
    if (typeof value === "string") {
        const bytes = encoder.encode(value);
        return concat(head(3, bytes.length), bytes);
    }
    if (typeof value === "number") return head(0, value);
    if (Array.isArray(value)) return concat(head(4, value.length), ...value.map(encodeCBOR));
    const entries = Object.entries(value);
    return concat(head(5, entries.length), ...entries.flatMap(([key, item]) => [encodeCBOR(key), encodeCBOR(item)]));
}

const sha256 = async bytes => new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
const generate = curve => crypto.subtle.generateKey({ name: "ECDSA", namedCurve: curve }, true, ["sign", "verify"]);

/// A root, an intermediate and a device key, like Apple's, but self-made.
async function fakeDevice({ appId = APP_ID, aaguid = "appattestdevelop", counter = 0 } = {}) {
    const root = await generate("P-384");
    const intermediate = await generate("P-384");
    const leaf = await generate("P-256");
    const rootDER = await makeCertificate({
        subject: "Test Root", issuer: "Test Root", publicKey: root.publicKey, signingKey: root.privateKey, hash: "SHA-384", ca: true,
    });
    const intermediateDER = await makeCertificate({
        subject: "Test CA", issuer: "Test Root", publicKey: intermediate.publicKey, signingKey: root.privateKey, hash: "SHA-384", ca: true,
    });
    const point = new Uint8Array(await crypto.subtle.exportKey("raw", leaf.publicKey));
    const keyIdBytes = await sha256(point);
    const keyId = toBase64(keyIdBytes);

    async function attest(challenge, overrides = {}) {
        const authData = concat(
            await sha256(encoder.encode(overrides.appId ?? appId)), Uint8Array.of(0x40), Uint8Array.of(0, 0, 0, counter),
            encoder.encode(aaguid), Uint8Array.of(0, keyIdBytes.length), overrides.credentialId ?? keyIdBytes,
        );
        const nonce = await sha256(concat(authData, await sha256(encoder.encode(overrides.signedChallenge ?? challenge))));
        const nonceExtension = sequence(oid("1.2.840.113635.100.8.2"), octets(sequence(der(0xa1, octets(nonce)))));
        const leafDER = await makeCertificate({
            subject: keyId, issuer: "Test CA", publicKey: leaf.publicKey, signingKey: intermediate.privateKey, hash: "SHA-256",
            extensions: [nonceExtension],
        });
        return encodeCBOR({ fmt: "apple-appattest", attStmt: { x5c: [leafDER, intermediateDER], receipt: new Uint8Array(4) }, authData });
    }

    async function makeAssertion(challenge, { assertCounter = 1, signingKey = leaf.privateKey } = {}) {
        const authenticatorData = concat(await sha256(encoder.encode(appId)), Uint8Array.of(0x40), Uint8Array.of(0, 0, 0, assertCounter));
        const nonce = await sha256(concat(authenticatorData, await sha256(encoder.encode(challenge))));
        const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signingKey, nonce));
        return encodeCBOR({ signature: rawToDERSignature(signature), authenticatorData });
    }

    return { rootDER, keyId, point, attest, makeAssertion, otherKey: (await generate("P-256")).privateKey };
}

// MARK: - Tests

test("Apple's App Attestation root parses and is self-signed", async () => {
    const der = fromBase64(APPLE_ROOT_PEM.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""));
    const root = parseCertificate(der);
    assert.equal(root.curveOID, "1.3.132.0.34");
    assert.equal(root.notAfter.toISOString(), "2045-03-15T00:00:00.000Z");
    assert.equal(await isSignedBy(root, root), true);
});

test("accepts a valid attestation and returns the device key", async () => {
    const device = await fakeDevice();
    const result = await verifyAttestation({
        attestation: await device.attest("challenge"), challenge: "challenge", keyId: device.keyId,
        appIds: ["OTHER.app", APP_ID], root: device.rootDER,
    });
    assert.deepEqual(result.publicKey, device.point);
    assert.equal(result.appId, APP_ID);
    assert.equal(result.environment, "development");
});

test("rejects attestations that don't match", async () => {
    const device = await fakeDevice();
    const verify = async (attestation, options = {}) => verifyAttestation({
        attestation, challenge: "challenge", keyId: device.keyId, appIds: [APP_ID], root: device.rootDER, ...options,
    });
    // Another challenge, another app, another key ID, another credential, a foreign root.
    await assert.rejects(verify(await device.attest("challenge", { signedChallenge: "old" })));
    await assert.rejects(verify(await device.attest("challenge", { appId: "EVIL.app" })));
    await assert.rejects(verify(await device.attest("challenge"), { keyId: toBase64(new Uint8Array(32)) }));
    await assert.rejects(verify(await device.attest("challenge", { credentialId: new Uint8Array(32) })));
    await assert.rejects(verify(await device.attest("challenge"), { root: (await fakeDevice()).rootDER }));
    // The real Apple root didn't sign the fake chain.
    await assert.rejects(verifyAttestation({ attestation: await device.attest("c"), challenge: "c", keyId: device.keyId, appIds: [APP_ID] }));
    // Used keys and unknown environments.
    await assert.rejects(verify(await (await fakeDevice({ counter: 1 })).attest("challenge")));
    await assert.rejects(verify(await (await fakeDevice({ aaguid: "somethingelse123" })).attest("challenge")));
    await assert.rejects(verify(new Uint8Array([0xff, 0x00])));
});

test("checks assertions with the attested key", async () => {
    const device = await fakeDevice();
    const check = async assertion => verifyAssertion({ assertion, challenge: "c2", publicKey: device.point, appId: APP_ID });
    await check(await device.makeAssertion("c2"));
    await assert.rejects(check(await device.makeAssertion("other")));
    await assert.rejects(check(await device.makeAssertion("c2", { signingKey: device.otherKey })));
    await assert.rejects(check(await device.makeAssertion("c2", { assertCounter: 0 })));
    await assert.rejects(verifyAssertion({ assertion: await device.makeAssertion("c2"), challenge: "c2", publicKey: device.point, appId: "EVIL.app" }));
});

test("signed tokens verify only with their type, secret and before they expire", async () => {
    const now = Date.UTC(2026, 9, 1);
    const token = await signToken({ t: "a", exp: now / 1000 + 60 }, SECRET);
    assert.ok(await verifyToken(token, "a", SECRET, now));
    assert.equal(await verifyToken(token, "c", SECRET, now), null);
    assert.equal(await verifyToken(token, "a", "other", now), null);
    assert.equal(await verifyToken(token, "a", SECRET, now + 61_000), null);
    const [body] = token.split(".");
    assert.equal(await verifyToken(`${body}.AAAA`, "a", SECRET, now), null);
    assert.equal(await verifyToken("garbage", "a", SECRET, now), null);
});

test("converts DER signatures to raw r ‖ s", () => {
    const raw = derSignatureToRaw(Uint8Array.of(0x30, 0x07, 0x02, 0x02, 0x00, 0x80, 0x02, 0x01, 0x05), 4);
    assert.deepEqual(raw, Uint8Array.of(0, 0, 0, 0x80, 0, 0, 0, 5));
    assert.equal(derSignatureToRaw(Uint8Array.of(1, 2, 3), 4), null);
});

test("decodes the CBOR subset", () => {
    const value = decodeCBOR(Uint8Array.of(0xa2, 0x61, 0x61, 0x82, 0x01, 0x20, 0x61, 0x62, 0x42, 0xaa, 0xbb));
    assert.deepEqual(value.get("a"), [1, -1]);
    assert.deepEqual(value.get("b"), Uint8Array.of(0xaa, 0xbb));
    assert.throws(() => decodeCBOR(Uint8Array.of(0x5a, 0xff, 0xff, 0xff, 0xff)));
});

test("the /auth routes hand out a token for a genuine device only", async t => {
    const device = await fakeDevice();
    const env = { TOKEN_SECRET: SECRET, APP_IDS: APP_ID };
    const base = "https://proxy.example";
    const post = (path, body) => new Request(base + path, { method: "POST", body: JSON.stringify(body) });

    const { challenge } = await (await handleAuth(new Request(`${base}/auth/challenge`), env)).json();
    assert.ok(await verifyToken(challenge, "c", SECRET));

    // The fake chain isn't Apple's, so the real route refuses it…
    const refused = await handleAuth(post("/auth/attest", {
        keyId: device.keyId, attestation: toBase64(await device.attest(challenge)), challenge,
    }), env);
    assert.equal(refused.status, 403);

    // …while a key token like the one it hands out for Apple's chain gets an access token.
    const keyToken = await signToken({ t: "k", kid: device.keyId, pub: toBase64(device.point), app: APP_ID }, SECRET);
    const second = (await (await handleAuth(new Request(`${base}/auth/challenge`), env)).json()).challenge;
    const response = await handleAuth(post("/auth/token", {
        keyToken, assertion: toBase64(await device.makeAssertion(second)), challenge: second,
    }), env);
    assert.equal(response.status, 200);
    const { token, expiresIn } = await response.json();
    assert.equal(expiresIn, 3600);

    const request = new Request(`${base}/x`, { headers: { [TOKEN_HEADER]: token } });
    assert.equal(await isAuthorized(request, env), true);
    assert.equal(await isAuthorized(request, env, { required: true }), true);

    // A wrong signature, a forged key token, a reused-but-expired challenge.
    const third = (await (await handleAuth(new Request(`${base}/auth/challenge`), env)).json()).challenge;
    const badAssertion = await handleAuth(post("/auth/token", {
        keyToken, assertion: toBase64(await device.makeAssertion(third, { signingKey: device.otherKey })), challenge: third,
    }), env);
    assert.equal(badAssertion.status, 403);
    const forged = await handleAuth(post("/auth/token", { keyToken: keyToken + "x", assertion: "", challenge: third }), env);
    assert.equal(forged.status, 401);
    const expired = await handleAuth(post("/auth/token", {
        keyToken, assertion: toBase64(await device.makeAssertion(third)), challenge: third,
    }), env, Date.now() + 10 * 60_000);
    assert.equal(expired.status, 400);
    t.diagnostic("attestation, token and refusal paths covered");
});

test("requests without a token are only let through during the rollout", async () => {
    const plain = new Request("https://proxy.example/x");
    const forged = new Request("https://proxy.example/x", { headers: { [TOKEN_HEADER]: "nope" } });
    assert.equal(await isAuthorized(plain, { TOKEN_SECRET: SECRET }), false);
    assert.equal(await isAuthorized(plain, { TOKEN_SECRET: SECRET, ALLOW_UNATTESTED: "true" }), true);
    assert.equal(await isAuthorized(plain, { TOKEN_SECRET: SECRET, ALLOW_UNATTESTED: "true" }, { required: true }), false);
    assert.equal(await isAuthorized(forged, { TOKEN_SECRET: SECRET, ALLOW_UNATTESTED: "true" }), false);
});

test("auth routes need their secrets", async () => {
    const response = await handleAuth(new Request("https://proxy.example/auth/challenge"), {});
    assert.equal(response.status, 503);
    assert.equal(await handleAuth(new Request("https://proxy.example/other"), {}), null);
});
