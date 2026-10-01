// App Attest for BetterBahn's Workers: only the genuine app on a real Apple device gets an access
// token, so the bahn.de proxy and the pass signer can't be used by anyone else. Stateless: every
// token is signed with TOKEN_SECRET (the same secret in every Worker), nothing is stored.
//
// 1. GET  /auth/challenge                               → { challenge }
// 2. POST /auth/attest { keyId, attestation, challenge } → { keyToken }   (once per app install)
// 3. POST /auth/token  { keyToken, assertion, challenge } → { token, expiresIn }
//
// Requests then carry the token as `X-BetterBahn-Token`. The app's side is `WorkerAuth` in
// BetterBahnKit. Checks follow Apple's "Validating apps that connect to your server".

export const TOKEN_HEADER = "X-BetterBahn-Token";
export const CHALLENGE_TTL = 5 * 60;
export const TOKEN_TTL = 60 * 60;
const MAX_BODY_BYTES = 32 * 1024;

// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
// SHA-256 fingerprint 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
export const APPLE_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

const NONCE_OID = "1.2.840.113635.100.8.2";
const BASIC_CONSTRAINTS_OID = "2.5.29.19";
const CURVES = { "1.2.840.10045.3.1.7": { name: "P-256", size: 32 }, "1.3.132.0.34": { name: "P-384", size: 48 } };
const SIGNATURE_HASHES = { "1.2.840.10045.4.3.2": "SHA-256", "1.2.840.10045.4.3.3": "SHA-384" };
const AAGUID_PRODUCTION = bytesOf("appattest\0\0\0\0\0\0\0");
const AAGUID_DEVELOPMENT = bytesOf("appattestdevelop");

export class AttestError extends Error {}

// MARK: - Routes

function json(status, body) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
    });
}

/// Answers `/auth/…`, or null for any other path.
export async function handleAuth(request, env = {}, now = Date.now()) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/auth/")) return null;
    const appIds = (env.APP_IDS ?? "").split(",").map(id => id.trim()).filter(Boolean);
    if (!env.TOKEN_SECRET || appIds.length === 0) return json(503, { error: "not_configured" });

    if (url.pathname === "/auth/challenge") {
        if (request.method !== "GET") return json(405, { error: "method_not_allowed" });
        const nonce = base64url(crypto.getRandomValues(new Uint8Array(16)));
        const challenge = await signToken({ t: "c", n: nonce, exp: Math.floor(now / 1000) + CHALLENGE_TTL }, env.TOKEN_SECRET);
        return json(200, { challenge });
    }
    if (url.pathname !== "/auth/attest" && url.pathname !== "/auth/token") return json(404, { error: "not_found" });
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

    const body = await request.arrayBuffer();
    if (body.byteLength > MAX_BODY_BYTES) return json(413, { error: "too_large" });
    let input;
    try {
        input = JSON.parse(new TextDecoder().decode(body));
    } catch {
        return json(400, { error: "invalid_json" });
    }
    if (!input || typeof input.challenge !== "string" || !(await verifyToken(input.challenge, "c", env.TOKEN_SECRET, now))) {
        return json(400, { error: "invalid_challenge" });
    }

    if (url.pathname === "/auth/attest") {
        try {
            if (typeof input.keyId !== "string" || typeof input.attestation !== "string") throw new AttestError("input");
            const result = await verifyAttestation({
                attestation: fromBase64(input.attestation), challenge: input.challenge, keyId: input.keyId,
                appIds, now: new Date(now),
            });
            const keyToken = await signToken({ t: "k", kid: input.keyId, pub: toBase64(result.publicKey), app: result.appId },
                env.TOKEN_SECRET);
            return json(200, { keyToken });
        } catch {
            return json(403, { error: "attestation_failed" });
        }
    }

    // A key token that no longer verifies (e.g. TOKEN_SECRET rotated) makes the app attest a new key.
    const key = await verifyToken(input.keyToken, "k", env.TOKEN_SECRET, now);
    if (!key) return json(401, { error: "invalid_key" });
    try {
        if (typeof input.assertion !== "string") throw new AttestError("input");
        await verifyAssertion({
            assertion: fromBase64(input.assertion), challenge: input.challenge,
            publicKey: fromBase64(key.pub), appId: key.app,
        });
    } catch {
        return json(403, { error: "assertion_failed" });
    }
    const token = await signToken({ t: "a", kid: key.kid, exp: Math.floor(now / 1000) + TOKEN_TTL }, env.TOKEN_SECRET);
    return json(200, { token, expiresIn: TOKEN_TTL });
}

/// Whether `request` may use the Worker: a valid access token, or no token at all while
/// `ALLOW_UNATTESTED` is "true" (only for the rollout, so builds without App Attest keep working)
/// and the route doesn't insist (`required`).
export async function isAuthorized(request, env = {}, { required = false, now = Date.now() } = {}) {
    const token = request.headers.get(TOKEN_HEADER);
    if (token) return Boolean(env.TOKEN_SECRET && await verifyToken(token, "a", env.TOKEN_SECRET, now));
    return !required && env.ALLOW_UNATTESTED === "true";
}

export const unauthorized = () => json(401, { error: "unauthorized" });

// MARK: - Signed tokens

async function hmacKey(secret) {
    return crypto.subtle.importKey("raw", bytesOf(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function signToken(payload, secret) {
    const body = base64url(bytesOf(JSON.stringify(payload)));
    const mac = await crypto.subtle.sign("HMAC", await hmacKey(secret), bytesOf(body));
    return `${body}.${base64url(new Uint8Array(mac))}`;
}

/// The payload of a token of `type` signed with `secret` that hasn't expired, or null.
export async function verifyToken(token, type, secret, now = Date.now()) {
    if (typeof token !== "string" || token.length > 4096) return null;
    const parts = token.split(".");
    if (parts.length !== 2) return null;
    try {
        const valid = await crypto.subtle.verify("HMAC", await hmacKey(secret), fromBase64url(parts[1]), bytesOf(parts[0]));
        if (!valid) return null;
        const payload = JSON.parse(new TextDecoder().decode(fromBase64url(parts[0])));
        if (payload?.t !== type) return null;
        if (payload.exp !== undefined && !(payload.exp * 1000 > now)) return null;
        return payload;
    } catch {
        return null;
    }
}

// MARK: - Attestation and assertion

/// Checks an attestation object from `DCAppAttestService.attestKey` and returns the key's public
/// key (uncompressed P-256 point), the matching app ID and the environment. Throws if anything is off.
export async function verifyAttestation({ attestation, challenge, keyId, appIds, root = pemToDER(APPLE_ROOT_PEM), now = new Date() }) {
    const object = decodeCBOR(attestation);
    if (!(object instanceof Map) || object.get("fmt") !== "apple-appattest") throw new AttestError("format");
    const statement = object.get("attStmt");
    const authData = object.get("authData");
    const x5c = statement instanceof Map ? statement.get("x5c") : null;
    if (!Array.isArray(x5c) || x5c.length < 2 || !(authData instanceof Uint8Array)) throw new AttestError("format");
    if (!x5c.every(cert => cert instanceof Uint8Array)) throw new AttestError("format");

    // 1. The certificates chain up to Apple's App Attestation root.
    const leaf = parseCertificate(x5c[0]);
    const intermediate = parseCertificate(x5c[1]);
    const anchor = parseCertificate(root);
    for (const cert of [leaf, intermediate, anchor]) {
        if (!(cert.notBefore <= now && now <= cert.notAfter)) throw new AttestError("validity");
    }
    if (!isCA(intermediate)) throw new AttestError("chain");
    if (!(await isSignedBy(intermediate, anchor)) || !(await isSignedBy(leaf, intermediate))) throw new AttestError("chain");

    // 2.–4. The leaf certificate carries SHA256(authData ‖ SHA256(challenge)).
    const clientDataHash = await sha256(bytesOf(challenge));
    const nonce = await sha256(concat(authData, clientDataHash));
    if (!equal(nonceFromExtension(leaf.extensions.get(NONCE_OID)), nonce)) throw new AttestError("nonce");

    // 5. The key ID is the hash of the leaf's public key.
    const keyIdBytes = fromBase64(keyId);
    if (CURVES[leaf.curveOID]?.name !== "P-256" || !equal(await sha256(leaf.publicKey), keyIdBytes)) {
        throw new AttestError("key");
    }

    // 6.–9. Authenticator data: our app, a fresh key, a known environment, the same key ID.
    const data = parseAuthData(authData);
    const appId = await matchingAppId(data.rpIdHash, appIds);
    if (!appId) throw new AttestError("app");
    if (data.counter !== 0) throw new AttestError("counter");
    const environment = equal(data.aaguid, AAGUID_PRODUCTION) ? "production"
        : equal(data.aaguid, AAGUID_DEVELOPMENT) ? "development" : null;
    if (!environment) throw new AttestError("environment");
    if (!equal(data.credentialId, keyIdBytes)) throw new AttestError("credential");

    return { publicKey: leaf.publicKey, appId, environment };
}

/// Checks an assertion from `DCAppAttestService.generateAssertion` made for `challenge` with the
/// attested key. Throws if it doesn't verify.
export async function verifyAssertion({ assertion, challenge, publicKey, appId }) {
    const object = decodeCBOR(assertion);
    const signature = object instanceof Map ? object.get("signature") : null;
    const authenticatorData = object instanceof Map ? object.get("authenticatorData") : null;
    if (!(signature instanceof Uint8Array) || !(authenticatorData instanceof Uint8Array) || authenticatorData.length < 37) {
        throw new AttestError("format");
    }
    const clientDataHash = await sha256(bytesOf(challenge));
    const nonce = await sha256(concat(authenticatorData, clientDataHash));
    const key = await crypto.subtle.importKey("raw", publicKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const raw = derSignatureToRaw(signature, 32);
    if (!raw || !(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, nonce))) {
        throw new AttestError("signature");
    }
    if (!equal(authenticatorData.subarray(0, 32), await sha256(bytesOf(appId)))) throw new AttestError("app");
    if (readUint32(authenticatorData, 33) === 0) throw new AttestError("counter");
}

async function matchingAppId(rpIdHash, appIds) {
    for (const appId of appIds) if (equal(rpIdHash, await sha256(bytesOf(appId)))) return appId;
    return null;
}

function parseAuthData(data) {
    if (data.length < 55) throw new AttestError("authData");
    const length = (data[53] << 8) | data[54];
    if (data.length < 55 + length) throw new AttestError("authData");
    return {
        rpIdHash: data.subarray(0, 32),
        counter: readUint32(data, 33),
        aaguid: data.subarray(37, 53),
        credentialId: data.subarray(55, 55 + length),
    };
}

/// The nonce in Apple's extension: SEQUENCE { [1] EXPLICIT OCTET STRING }.
function nonceFromExtension(value) {
    if (!value) throw new AttestError("nonce");
    for (const element of children(parseDER(value))) {
        if (element.tag === 0xa1) {
            const [octets] = children(element);
            if (octets?.tag === 0x04) return octets.content;
        }
    }
    throw new AttestError("nonce");
}

// MARK: - X.509

export function parseCertificate(der) {
    const certificate = parseDER(der);
    if (certificate.end !== der.length) throw new AttestError("certificate");
    const [tbs, algorithm, signature] = children(certificate);
    if (!tbs || !algorithm || signature?.tag !== 0x03) throw new AttestError("certificate");
    const fields = children(tbs);
    let index = fields[0]?.tag === 0xa0 ? 1 : 0;
    index += 2; // serial number, signature algorithm
    const issuer = fields[index++];
    const validity = fields[index++];
    const subject = fields[index++];
    const spki = fields[index++];
    if (!issuer || !validity || !subject || !spki) throw new AttestError("certificate");

    const extensions = new Map();
    for (const field of fields.slice(index)) {
        if (field.tag !== 0xa3) continue;
        for (const extension of children(children(field)[0])) {
            const parts = children(extension);
            extensions.set(decodeOID(parts[0].content), parts[parts.length - 1].content);
        }
    }
    const [notBefore, notAfter] = children(validity).map(parseTime);
    const [keyAlgorithm, keyBits] = children(spki);
    return {
        tbs: tbs.raw,
        signatureAlgorithm: decodeOID(children(algorithm)[0].content),
        signature: signature.content.subarray(1),
        issuer: issuer.raw,
        subject: subject.raw,
        notBefore,
        notAfter,
        spki: spki.raw,
        curveOID: decodeOID(children(keyAlgorithm)[1]?.content ?? new Uint8Array()),
        publicKey: keyBits.content.subarray(1),
        extensions,
    };
}

export async function isSignedBy(certificate, issuer) {
    if (!equal(certificate.issuer, issuer.subject)) return false;
    const hash = SIGNATURE_HASHES[certificate.signatureAlgorithm];
    const curve = CURVES[issuer.curveOID];
    if (!hash || !curve) return false;
    const raw = derSignatureToRaw(certificate.signature, curve.size);
    if (!raw) return false;
    const key = await crypto.subtle.importKey("spki", issuer.spki, { name: "ECDSA", namedCurve: curve.name }, false, ["verify"]);
    return crypto.subtle.verify({ name: "ECDSA", hash }, key, raw, certificate.tbs);
}

function isCA(certificate) {
    const value = certificate.extensions.get(BASIC_CONSTRAINTS_OID);
    if (!value) return false;
    const [flag] = children(parseDER(value));
    return flag?.tag === 0x01 && flag.content[0] !== 0;
}

/// ECDSA-Sig-Value (SEQUENCE of r and s) → r ‖ s, as WebCrypto wants it.
export function derSignatureToRaw(signature, size) {
    try {
        const sequence = parseDER(signature);
        const [r, s] = children(sequence);
        if (r?.tag !== 0x02 || s?.tag !== 0x02) return null;
        const out = new Uint8Array(size * 2);
        for (const [index, integer] of [r, s].entries()) {
            let bytes = integer.content;
            while (bytes.length > 1 && bytes[0] === 0) bytes = bytes.subarray(1);
            if (bytes.length > size) return null;
            out.set(bytes, (index + 1) * size - bytes.length);
        }
        return out;
    } catch {
        return null;
    }
}

function parseTime(node) {
    const text = new TextDecoder().decode(node.content);
    const match = node.tag === 0x17 ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
        : node.tag === 0x18 ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text) : null;
    if (!match) throw new AttestError("time");
    let year = Number(match[1]);
    if (node.tag === 0x17) year += year < 50 ? 2000 : 1900;
    return new Date(Date.UTC(year, Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6])));
}

// MARK: - DER

export function parseDER(bytes, offset = 0, limit = bytes.length) {
    if (offset + 2 > limit) throw new AttestError("der");
    const tag = bytes[offset];
    let length = bytes[offset + 1];
    let header = 2;
    if (length & 0x80) {
        const count = length & 0x7f;
        if (count < 1 || count > 4 || offset + 2 + count > limit) throw new AttestError("der");
        length = 0;
        for (let i = 0; i < count; i++) length = length * 256 + bytes[offset + 2 + i];
        header += count;
    }
    const contentStart = offset + header;
    const end = contentStart + length;
    if (end > limit) throw new AttestError("der");
    return { bytes, tag, contentStart, end, content: bytes.subarray(contentStart, end), raw: bytes.subarray(offset, end) };
}

export function children(node) {
    if (!node || !(node.tag & 0x20)) throw new AttestError("der");
    const out = [];
    let position = node.contentStart;
    while (position < node.end) {
        const child = parseDER(node.bytes, position, node.end);
        out.push(child);
        position = child.end;
    }
    return out;
}

function decodeOID(bytes) {
    if (bytes.length === 0) return "";
    const parts = [Math.floor(bytes[0] / 40), bytes[0] % 40];
    let value = 0;
    for (const byte of bytes.subarray(1)) {
        value = value * 128 + (byte & 0x7f);
        if (!(byte & 0x80)) {
            parts.push(value);
            value = 0;
        }
    }
    return parts.join(".");
}

function pemToDER(pem) {
    return fromBase64(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""));
}

// MARK: - CBOR (the subset App Attest uses: integers, byte/text strings, arrays, maps)

export function decodeCBOR(bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let position = 0;
    const need = count => {
        if (position + count > bytes.length) throw new AttestError("cbor");
    };
    const length = info => {
        if (info < 24) return info;
        const size = { 24: 1, 25: 2, 26: 4 }[info];
        if (!size) throw new AttestError("cbor");
        need(size);
        const value = size === 1 ? view.getUint8(position) : size === 2 ? view.getUint16(position) : view.getUint32(position);
        position += size;
        return value;
    };
    const item = depth => {
        if (depth > 8) throw new AttestError("cbor");
        need(1);
        const initial = bytes[position++];
        const major = initial >> 5;
        const count = length(initial & 31);
        switch (major) {
            case 0: return count;
            case 1: return -1 - count;
            case 2:
            case 3: {
                need(count);
                const value = bytes.subarray(position, position + count);
                position += count;
                return major === 2 ? value : new TextDecoder().decode(value);
            }
            case 4: {
                const array = [];
                for (let i = 0; i < count; i++) array.push(item(depth + 1));
                return array;
            }
            case 5: {
                const map = new Map();
                for (let i = 0; i < count; i++) {
                    const key = item(depth + 1);
                    map.set(key, item(depth + 1));
                }
                return map;
            }
            default: throw new AttestError("cbor");
        }
    };
    return item(0);
}

// MARK: - Bytes

function bytesOf(text) {
    return new TextEncoder().encode(text);
}

async function sha256(bytes) {
    return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function concat(...parts) {
    const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
    let position = 0;
    for (const part of parts) {
        out.set(part, position);
        position += part.length;
    }
    return out;
}

function equal(a, b) {
    if (!a || !b || a.length !== b.length) return false;
    let difference = 0;
    for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
    return difference === 0;
}

function readUint32(bytes, offset) {
    return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

export function toBase64(bytes) {
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
}

export function fromBase64(text) {
    const binary = atob(text);
    return Uint8Array.from(binary, character => character.charCodeAt(0));
}

function base64url(bytes) {
    return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text) {
    const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
    return fromBase64(base64.padEnd(Math.ceil(base64.length / 4) * 4, "="));
}
