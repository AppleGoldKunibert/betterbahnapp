// Checks the issuer's signature on UIC ticket barcodes ("#UT", IRS 90918-9 static barcode), so the pass
// signer only puts genuine tickets into Wallet passes signed with our certificate. A screenshot of a
// made-up or altered code is refused.
//
// The issuers' public keys come from UIC's key list (https://railpublickey.uic.org), cached for a
// day. The barcode names its issuer (RICS code) and key ID; the signature covers the compressed
// ticket data. Version 1 barcodes carry a DER signature padded to 50 bytes (DSA 1024/SHA-1),
// version 2 one of 64 bytes, DER or plain r ‖ s (DSA 2048/SHA-256 at DB). WebCrypto has no DSA, so
// that is checked here with BigInt; ECDSA keys go through WebCrypto.

import { createHash } from "node:crypto";
import { children, decodeOID, fromBase64, parseCertificate, parseDER } from "../shared/appattest.mjs";

export const KEY_LIST_URL = "https://railpublickey.uic.org/download.php";
export const KEY_LIST_TTL = 24 * 60 * 60;

const DSA_OID = "1.2.840.10040.4.1";
const EC_OID = "1.2.840.10045.2.1";
const CURVES = { "1.2.840.10045.3.1.7": { name: "P-256", size: 32 }, "1.3.132.0.34": { name: "P-384", size: 48 } };

// MARK: - Key list

/// "1080" + "00007" → "1080/7"; alphanumeric key IDs (some issuers use them) stay as they are.
export function keyRef(issuer, id) {
    const number = text => (/^\d+$/.test(text) ? String(Number(text)) : text.toUpperCase());
    return `${number(String(issuer).trim())}/${number(String(id).trim())}`;
}

/// UIC's key list (XML) → issuer/key ID → [{ algorithm, publicKey (base64 certificate or SPKI) }].
/// Keys marked as forged are left out.
export function parseKeyList(xml) {
    const keys = new Map();
    for (const [, block] of xml.matchAll(/<key>([\s\S]*?)<\/key>/g)) {
        const field = name => block.match(new RegExp(`<${name}>([^<]*)</${name}>`))?.[1]?.trim() ?? "";
        const issuer = field("issuerCode"), id = field("id"), publicKey = field("publicKey").replace(/\s+/g, "");
        if (!issuer || !id || !publicKey || /^(true|yes|1)$/i.test(field("keyForged"))) continue;
        const ref = keyRef(issuer, id);
        keys.set(ref, [...(keys.get(ref) ?? []), { algorithm: field("signatureAlgorithm"), publicKey }]);
    }
    return keys;
}

let memory = null;

/// The parsed key list: kept in memory and in Cloudflare's cache for a day. If UIC can't be reached,
/// an older copy still in memory is used; without any copy this throws.
export async function loadKeyList({ fetch = globalThis.fetch, cache = null, now = Date.now() } = {}) {
    if (memory && now - memory.loadedAt < KEY_LIST_TTL * 1000) return memory.keys;
    try {
        let xml;
        const cached = cache && await cache.match(KEY_LIST_URL);
        if (cached) {
            xml = await cached.text();
        } else {
            const response = await fetch(KEY_LIST_URL, { headers: { Accept: "application/xml" } });
            if (!response.ok) throw new Error(`key list: ${response.status}`);
            xml = await response.text();
            if (cache) {
                await cache.put(KEY_LIST_URL, new Response(xml, {
                    headers: { "Content-Type": "application/xml", "Cache-Control": `public, max-age=${KEY_LIST_TTL}` },
                }));
            }
        }
        const keys = parseKeyList(xml);
        if (keys.size === 0) throw new Error("key list: empty");
        memory = { keys, loadedAt: now };
        return keys;
    } catch (error) {
        if (memory) return memory.keys;
        throw error;
    }
}

/// For tests: forget the key list kept in memory.
export function resetKeyListMemory() {
    memory = null;
}

// MARK: - Barcode

/// Header fields of a "#UT" barcode and the bytes its signature covers, or null for anything else.
export function parseUICBarcode(bytes) {
    if (bytes.length < 14) return null;
    const header = String.fromCharCode(...bytes.subarray(0, 14));
    const match = /^#UT(0[12])(\d{4})([0-9A-Za-z]{5})$/.exec(header);
    if (!match) return null;
    const signatureLength = match[1] === "01" ? 50 : 64;
    const lengthStart = 14 + signatureLength;
    const lengthText = String.fromCharCode(...bytes.subarray(lengthStart, lengthStart + 4));
    if (!/^\d{4}$/.test(lengthText)) return null;
    const dataStart = lengthStart + 4;
    const length = Number(lengthText);
    if (length === 0 || dataStart + length > bytes.length) return null;
    return {
        version: Number(match[1]),
        key: keyRef(match[2], match[3]),
        signature: bytes.subarray(14, lengthStart),
        signed: bytes.subarray(dataStart, dataStart + length),
    };
}

/// Whether `bytes` is a "#UT" barcode whose signature verifies with its issuer's key from `keys`.
export async function verifyUICBarcode(bytes, keys) {
    const barcode = parseUICBarcode(bytes);
    if (!barcode) return false;
    for (const key of keys.get(barcode.key) ?? []) {
        try {
            if (await verifyWithKey(key, barcode.signature, barcode.signed)) return true;
        } catch {
            // An unreadable key or signature just doesn't verify.
        }
    }
    return false;
}

/// A barcode message as Wallet gets it (ISO-8859-1: one character per byte) → its bytes, or null.
export function messageBytes(message) {
    const bytes = new Uint8Array(message.length);
    for (let i = 0; i < message.length; i++) {
        const code = message.charCodeAt(i);
        if (code > 0xff) return null;
        bytes[i] = code;
    }
    return bytes;
}

// MARK: - Signatures

async function verifyWithKey(key, signature, message) {
    const spki = subjectPublicKeyInfo(fromBase64(key.publicKey));
    const [algorithm, keyBits] = children(spki);
    const [oid, parameters] = children(algorithm);
    const type = decodeOID(oid.content);
    const candidates = signatureCandidates(signature);

    if (type === DSA_OID) {
        const [p, q, g] = children(parameters).map(integer => bigInt(integer.content));
        const y = bigInt(parseDER(keyBits.content.subarray(1)).content);
        const hash = await digest(hashName(key.algorithm, bitLength(q)), message);
        return candidates.some(({ r, s }) => dsaVerify({ p, q, g, y }, hash, r, s));
    }
    if (type === EC_OID) {
        const curve = CURVES[decodeOID(parameters.content)];
        if (!curve) return false;
        const publicKey = await crypto.subtle.importKey("spki", spki.raw, { name: "ECDSA", namedCurve: curve.name }, false, ["verify"]);
        const hash = hashName(key.algorithm, 256);
        if (hash === "SHA-224") return false;
        for (const { r, s } of candidates) {
            const raw = new Uint8Array(curve.size * 2);
            if (!putFixed(raw, r, 0, curve.size) || !putFixed(raw, s, curve.size, curve.size)) continue;
            if (await crypto.subtle.verify({ name: "ECDSA", hash }, publicKey, raw, message)) return true;
        }
    }
    return false;
}

/// UIC's list has X.509 certificates; a bare SubjectPublicKeyInfo works too.
function subjectPublicKeyInfo(der) {
    const node = parseDER(der);
    if (children(node)[1]?.tag === 0x03) return node;
    return parseDER(parseCertificate(der).spki);
}

/// (r, s) read as DER and, as a fallback, as plain r ‖ s halves; whichever verifies counts.
function signatureCandidates(bytes) {
    const candidates = [];
    if (bytes[0] === 0x30) {
        try {
            const [r, s] = children(parseDER(bytes));
            if (r?.tag === 0x02 && s?.tag === 0x02) candidates.push({ r: bigInt(r.content), s: bigInt(s.content) });
        } catch {
            // Not DER after all.
        }
    }
    const half = bytes.length / 2;
    candidates.push({ r: bigInt(bytes.subarray(0, half)), s: bigInt(bytes.subarray(half)) });
    return candidates;
}

/// The hash named in UIC's algorithm text (e.g. "SHA256withDSA(2048,256)", "SHA1-DSA (1024)"), or,
/// for DSA texts without one ("DSA1024"), the one matching the key's q.
export function hashName(algorithm, qBits) {
    const text = algorithm.toLowerCase().replace(/[\s_-]/g, "");
    for (const [needle, name] of [["sha512", "SHA-512"], ["sha384", "SHA-384"], ["sha256", "SHA-256"], ["sha224", "SHA-224"], ["sha1", "SHA-1"]]) {
        if (text.includes(needle)) return name;
    }
    return qBits <= 160 ? "SHA-1" : qBits <= 224 ? "SHA-224" : "SHA-256";
}

async function digest(name, bytes) {
    // WebCrypto has no SHA-224.
    if (name === "SHA-224") return new Uint8Array(createHash("sha224").update(bytes).digest());
    return new Uint8Array(await crypto.subtle.digest(name, bytes));
}

/// FIPS 186-4 DSA verification.
export function dsaVerify({ p, q, g, y }, hash, r, s) {
    if (r <= 0n || r >= q || s <= 0n || s >= q) return false;
    const w = modInverse(s, q);
    const n = bitLength(q);
    let z = bigInt(hash);
    if (hash.length * 8 > n) z >>= BigInt(hash.length * 8 - n);
    const u1 = (z * w) % q;
    const u2 = (r * w) % q;
    return ((modPow(g, u1, p) * modPow(y, u2, p)) % p) % q === r;
}

// MARK: - BigInt

function bigInt(bytes) {
    let value = 0n;
    for (const byte of bytes) value = (value << 8n) | BigInt(byte);
    return value;
}

function bitLength(value) {
    return value.toString(2).length;
}

function modPow(base, exponent, modulus) {
    let result = 1n;
    base %= modulus;
    while (exponent > 0n) {
        if (exponent & 1n) result = (result * base) % modulus;
        base = (base * base) % modulus;
        exponent >>= 1n;
    }
    return result;
}

function modInverse(value, modulus) {
    let [a, b, x, previous] = [value % modulus, modulus, 1n, 0n];
    while (b !== 0n) {
        const quotient = a / b;
        [a, b] = [b, a - quotient * b];
        [x, previous] = [previous, x - quotient * previous];
    }
    return ((x % modulus) + modulus) % modulus;
}

/// Writes `value` big-endian into `size` bytes at `offset`; false if it doesn't fit.
function putFixed(out, value, offset, size) {
    for (let i = size - 1; i >= 0; i--) {
        out[offset + i] = Number(value & 0xffn);
        value >>= 8n;
    }
    return value === 0n;
}
