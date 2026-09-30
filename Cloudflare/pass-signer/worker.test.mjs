import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import forge from "node-forge";
import { buildPass, crc32, handleRequest, isValidPayload, MAX_BODY_BYTES } from "./worker.mjs";

const base = "https://betterbahn-pass.example.workers.dev";

// A throwaway CA + pass certificate, standing in for Apple's WWDR and the Pass Type ID certificate.
function testEnv() {
    const make = (subject, issuer, signingKey, publicKey) => {
        const cert = forge.pki.createCertificate();
        cert.publicKey = publicKey;
        cert.serialNumber = String(Math.floor(Math.random() * 1e9));
        cert.validity.notBefore = new Date(Date.now() - 86400000);
        cert.validity.notAfter = new Date(Date.now() + 86400000);
        cert.setSubject([{ name: "commonName", value: subject }]);
        cert.setIssuer([{ name: "commonName", value: issuer }]);
        cert.sign(signingKey, forge.md.sha256.create());
        return cert;
    };
    const ca = forge.pki.rsa.generateKeyPair(1024);
    const pass = forge.pki.rsa.generateKeyPair(1024);
    const wwdr = make("Test WWDR", "Test WWDR", ca.privateKey, ca.publicKey);
    const cert = make("Pass Type ID: pass.test", "Test WWDR", ca.privateKey, pass.publicKey);
    return {
        PASS_TYPE_ID: "pass.de.goldkunibert.BetterBahn.ticket",
        TEAM_ID: "ABCDE12345",
        PASS_CERT: forge.pki.certificateToPem(cert),
        PASS_KEY: forge.pki.privateKeyToPem(pass.privateKey),
        WWDR_CERT: forge.pki.certificateToPem(wwdr),
    };
}
const env = testEnv();

// Every byte value, like DB's binary UIC barcode (sent as ISO-8859-1 characters).
const message = String.fromCharCode(...Array.from({ length: 256 }, (_, i) => i));

function payload(extra = {}) {
    return {
        serialNumber: "123456789012-AB1C2345",
        description: "Sparpreis Europa Bernau → Bruxelles Midi",
        barcodes: [{ format: "PKBarcodeFormatAztec", message, messageEncoding: "iso-8859-1" }],
        boardingPass: { transitType: "PKTransitTypeTrain", primaryFields: [] },
        ...extra,
    };
}

function post(body, headers = {}) {
    return new Request(`${base}/pass`, {
        method: "POST",
        body: typeof body === "string" ? body : JSON.stringify(body),
        headers: { "Content-Type": "application/json", ...headers },
    });
}

// Reads a stored (uncompressed) zip as written by the worker.
function unzip(bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const files = new Map();
    let offset = 0;
    while (view.getUint32(offset, true) === 0x04034b50) {
        const crc = view.getUint32(offset + 14, true);
        const size = view.getUint32(offset + 18, true);
        const nameLength = view.getUint16(offset + 26, true);
        const name = new TextDecoder().decode(bytes.subarray(offset + 30, offset + 30 + nameLength));
        const data = bytes.subarray(offset + 30 + nameLength, offset + 30 + nameLength + size);
        assert.equal(crc32(data), crc, `crc of ${name}`);
        files.set(name, data);
        offset += 30 + nameLength + size;
    }
    return files;
}

test("signs a pass with manifest, images and a detached signature", async () => {
    const response = await handleRequest(post(payload()), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Type"), "application/vnd.apple.pkpass");
    assert.equal(response.headers.get("Cache-Control"), "no-store");

    const files = unzip(new Uint8Array(await response.arrayBuffer()));
    for (const name of ["pass.json", "icon.png", "icon@2x.png", "manifest.json", "signature"]) {
        assert.ok(files.has(name), name);
    }

    const pass = JSON.parse(new TextDecoder().decode(files.get("pass.json")));
    assert.equal(pass.formatVersion, 1);
    assert.equal(pass.passTypeIdentifier, env.PASS_TYPE_ID);
    assert.equal(pass.teamIdentifier, env.TEAM_ID);
    assert.equal(pass.barcodes[0].message, message, "barcode passed through unchanged");

    const manifest = JSON.parse(new TextDecoder().decode(files.get("manifest.json")));
    for (const [name, data] of files) {
        if (name === "manifest.json" || name === "signature") continue;
        assert.equal(manifest[name], createHash("sha1").update(data).digest("hex"), name);
    }

    const signature = files.get("signature");
    const p7 = forge.pkcs7.messageFromAsn1(forge.asn1.fromDer(forge.util.binary.raw.encode(signature)));
    assert.equal(p7.certificates.length, 2);
    assert.equal(p7.rawCapture.content, undefined, "detached");
    assert.equal(p7.rawCapture.signerInfos.length, 1);
});

test("keeps only known pass keys", async () => {
    const response = await handleRequest(post(payload({ webServiceURL: "https://evil.example", passTypeIdentifier: "x" })), env);
    const pass = JSON.parse(new TextDecoder().decode(unzip(new Uint8Array(await response.arrayBuffer())).get("pass.json")));
    assert.equal(pass.webServiceURL, undefined);
    assert.equal(pass.passTypeIdentifier, env.PASS_TYPE_ID);
});

test("rejects bad requests", async () => {
    assert.equal((await handleRequest(new Request(`${base}/pass`), env)).status, 405);
    assert.equal((await handleRequest(new Request(`${base}/other`, { method: "POST" }), env)).status, 404);
    assert.equal((await handleRequest(post("{nope"), env)).status, 400);
    assert.equal((await handleRequest(post({ serialNumber: "1" }), env)).status, 400);
    assert.equal((await handleRequest(post("x".repeat(MAX_BODY_BYTES + 1)), env)).status, 413);
    assert.equal((await handleRequest(post(payload()), {})).status, 503);
});

test("checks the shared token when one is set", async () => {
    const withToken = { ...env, PROXY_TOKEN: "secret" };
    assert.equal((await handleRequest(post(payload()), withToken)).status, 401);
    assert.equal((await handleRequest(post(payload(), { "X-BetterBahn-Token": "secret" }), withToken)).status, 200);
});

test("validates the payload shape", () => {
    assert.ok(isValidPayload(payload()));
    assert.ok(!isValidPayload(payload({ barcodes: [] })));
    assert.ok(!isValidPayload([]));
});

test("crc32 matches the reference value", () => {
    assert.equal(crc32(new TextEncoder().encode("123456789")), 0xcbf43926);
});

test("buildPass is deterministic apart from the signature", () => {
    const date = new Date("2026-10-01T12:00:00Z");
    const a = unzip(buildPass(payload(), env, date));
    const b = unzip(buildPass(payload(), env, date));
    assert.deepEqual(a.get("manifest.json"), b.get("manifest.json"));
});
