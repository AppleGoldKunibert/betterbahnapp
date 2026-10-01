// Signs Apple Wallet passes for BetterBahn's DB tickets. A pass must be signed with a Pass Type ID
// certificate, which can't ship inside the app, so the app sends its pass.json here and gets the
// signed .pkpass back. The barcode is passed through untouched: it is DB's own signed ticket code.

import forge from "node-forge";
import { isAuthorized, unauthorized } from "../shared/appattest.mjs";
import { IMAGES } from "./images.mjs";

export const MAX_BODY_BYTES = 16 * 1024;

// Only these pass.json keys are taken from the app; identity, issuer name, format and images come from here.
export const ORGANIZATION_NAME = "BetterBahn";
const ALLOWED_KEYS = [
    "serialNumber", "description", "foregroundColor", "labelColor", "backgroundColor",
    "relevantDate", "expirationDate", "barcodes", "boardingPass",
];

function json(status, body, extra = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
    });
}

export async function handleRequest(request, env = {}) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json(200, { ok: true });
    if (url.pathname !== "/pass") return json(404, { error: "not_found" });
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" }, { Allow: "POST" });

    // Only the genuine app may sign with our certificate: an App Attest token from the bahn.de proxy's
    // `/auth` routes (same TOKEN_SECRET), see ../shared/appattest.mjs.
    if (!(await isAuthorized(request, env))) return unauthorized();
    if (!env.PASS_TYPE_ID || !env.TEAM_ID || !env.PASS_CERT || !env.PASS_KEY || !env.WWDR_CERT) {
        return json(503, { error: "not_configured" });
    }

    const body = await request.arrayBuffer();
    if (body.byteLength > MAX_BODY_BYTES) return json(413, { error: "too_large" });
    let payload;
    try {
        payload = JSON.parse(new TextDecoder().decode(body));
    } catch {
        return json(400, { error: "invalid_json" });
    }
    if (!isValidPayload(payload)) return json(400, { error: "invalid_pass" });

    const pass = {
        formatVersion: 1, passTypeIdentifier: env.PASS_TYPE_ID, teamIdentifier: env.TEAM_ID, organizationName: ORGANIZATION_NAME,
    };
    for (const key of ALLOWED_KEYS) if (key in payload) pass[key] = payload[key];

    let pkpass;
    try {
        pkpass = buildPass(pass, env);
    } catch {
        return json(500, { error: "signing_failed" });
    }
    return new Response(pkpass, {
        status: 200,
        headers: {
            "Content-Type": "application/vnd.apple.pkpass",
            "Content-Disposition": 'attachment; filename="ticket.pkpass"',
            "Cache-Control": "no-store",
        },
    });
}

export function isValidPayload(payload) {
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return false;
    if (typeof payload.serialNumber !== "string" || !payload.serialNumber) return false;
    if (typeof payload.description !== "string") return false;
    if (!payload.boardingPass || typeof payload.boardingPass !== "object") return false;
    return Array.isArray(payload.barcodes) && payload.barcodes.length > 0
        && payload.barcodes.every(b => b && typeof b.message === "string" && typeof b.format === "string");
}

/// The .pkpass: pass.json, images, manifest.json (SHA-1 of every file) and a detached PKCS#7
/// signature of the manifest.
export function buildPass(pass, env, now = new Date()) {
    const files = new Map();
    files.set("pass.json", new TextEncoder().encode(JSON.stringify(pass)));
    for (const [name, base64] of Object.entries(IMAGES)) files.set(name, base64ToBytes(base64));

    const manifest = {};
    for (const [name, bytes] of files) manifest[name] = sha1Hex(bytes);
    const manifestBytes = new TextEncoder().encode(JSON.stringify(manifest));
    files.set("manifest.json", manifestBytes);
    files.set("signature", sign(manifestBytes, env, now));
    return zip(files, now);
}

export function sign(bytes, env, now = new Date()) {
    const certificate = forge.pki.certificateFromPem(env.PASS_CERT);
    const wwdr = forge.pki.certificateFromPem(env.WWDR_CERT);
    const key = env.PASS_KEY_PASSWORD
        ? forge.pki.decryptRsaPrivateKey(env.PASS_KEY, env.PASS_KEY_PASSWORD)
        : forge.pki.privateKeyFromPem(env.PASS_KEY);
    if (!key) throw new Error("unreadable key");

    const p7 = forge.pkcs7.createSignedData();
    p7.content = forge.util.createBuffer(bytesToBinary(bytes));
    p7.addCertificate(certificate);
    p7.addCertificate(wwdr);
    p7.addSigner({
        key,
        certificate,
        digestAlgorithm: forge.pki.oids.sha256,
        authenticatedAttributes: [
            { type: forge.pki.oids.contentType, value: forge.pki.oids.data },
            { type: forge.pki.oids.messageDigest },
            { type: forge.pki.oids.signingTime, value: now },
        ],
    });
    p7.sign({ detached: true });
    return binaryToBytes(forge.asn1.toDer(p7.toAsn1()).getBytes());
}

function sha1Hex(bytes) {
    const md = forge.md.sha1.create();
    md.update(bytesToBinary(bytes));
    return md.digest().toHex();
}

// MARK: - Zip (stored, no compression – passes are small and Wallet accepts it)

const CRC_TABLE = (() => {
    const table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        table[n] = c >>> 0;
    }
    return table;
})();

export function crc32(bytes) {
    let crc = 0xffffffff;
    for (const byte of bytes) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
    return (crc ^ 0xffffffff) >>> 0;
}

export function zip(files, date = new Date()) {
    const time = (date.getUTCHours() << 11) | (date.getUTCMinutes() << 5) | (date.getUTCSeconds() >> 1);
    const day = ((date.getUTCFullYear() - 1980) << 9) | ((date.getUTCMonth() + 1) << 5) | date.getUTCDate();
    const parts = [];
    const central = [];
    let offset = 0;
    for (const [name, data] of files) {
        const nameBytes = new TextEncoder().encode(name);
        const crc = crc32(data);
        const local = new DataView(new ArrayBuffer(30));
        local.setUint32(0, 0x04034b50, true);
        local.setUint16(4, 20, true);
        local.setUint16(6, 0x0800, true); // UTF-8 names
        local.setUint16(8, 0, true); // stored
        local.setUint16(10, time, true);
        local.setUint16(12, day, true);
        local.setUint32(14, crc, true);
        local.setUint32(18, data.length, true);
        local.setUint32(22, data.length, true);
        local.setUint16(26, nameBytes.length, true);
        parts.push(new Uint8Array(local.buffer), nameBytes, data);

        const entry = new DataView(new ArrayBuffer(46));
        entry.setUint32(0, 0x02014b50, true);
        entry.setUint16(4, 20, true);
        entry.setUint16(6, 20, true);
        entry.setUint16(8, 0x0800, true);
        entry.setUint16(10, 0, true);
        entry.setUint16(12, time, true);
        entry.setUint16(14, day, true);
        entry.setUint32(16, crc, true);
        entry.setUint32(20, data.length, true);
        entry.setUint32(24, data.length, true);
        entry.setUint16(28, nameBytes.length, true);
        entry.setUint32(42, offset, true);
        central.push(new Uint8Array(entry.buffer), nameBytes);
        offset += 30 + nameBytes.length + data.length;
    }
    const centralSize = central.reduce((sum, part) => sum + part.length, 0);
    const end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true);
    end.setUint16(8, files.size, true);
    end.setUint16(10, files.size, true);
    end.setUint32(12, centralSize, true);
    end.setUint32(16, offset, true);

    const all = [...parts, ...central, new Uint8Array(end.buffer)];
    const out = new Uint8Array(all.reduce((sum, part) => sum + part.length, 0));
    let position = 0;
    for (const part of all) {
        out.set(part, position);
        position += part.length;
    }
    return out;
}

// MARK: - Bytes

function base64ToBytes(base64) {
    return binaryToBytes(atob(base64));
}

function bytesToBinary(bytes) {
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return binary;
}

function binaryToBytes(binary) {
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

export default {
    fetch(request, env) {
        return handleRequest(request, env);
    },
};
