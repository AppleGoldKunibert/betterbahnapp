import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import test from "node:test";
import {
    KEY_LIST_URL, hashName, keyRef, loadKeyList, messageBytes, parseKeyList, parseUICBarcode, resetKeyListMemory,
    verifyUICBarcode,
} from "./uicsignature.mjs";

const hex = text => Uint8Array.from(Buffer.from(text, "hex"));
const ascii = text => Uint8Array.from(Buffer.from(text, "latin1"));
const concat = (...parts) => Uint8Array.from(Buffer.concat(parts.map(part => Buffer.from(part))));

/// A "#UT" barcode: header, signature padded to its field, length and the (compressed) data.
function barcode({ version = "02", issuer = "1080", key = "00012", signature, data }) {
    const field = new Uint8Array(version === "01" ? 50 : 64);
    field.set(signature);
    return concat(ascii(`#UT${version}${issuer}${key}`), field, ascii(String(data.length).padStart(4, "0")), data);
}

// A sample DB ticket ("Musterman", key 1080/7, barcode version 1) from the MIT-licensed uic-918-3
// library's tests (github.com/justusjonas74/uic-918-3), and DB's matching public key from UIC's list.
const DB_SAMPLE_SIGNATURE = hex("302C0214239CE59CD65ACA33FCC59C2141C51BA825EF1B400214352E9631C8405E2662207868C631959F45D21CDF");
const DB_SAMPLE_DATA = hex(
    "789C0B8DF77075743130343030353634B030F0B508313130767564400246E60646460646A686068686062EAE2EAEA1F1213E8E91404DC6868641CE2146060686C6406C01A48C811C034BB7C48CA2ECC4A29254A0B146407596062051DFD2E292D4A2DCC43C030333B8A8B16F6205D05CB05EA02B8C2C5C524B4B8A93337212F35274433293B3534B14BCF2934AC02C0343A07120080440B7189A9A02293310C72020B5A8383F4F23354FD3C018C835343001293201B9DBC00C2C600A12006AD003EA37333047881858012933B043116A8C812216081163B01A33339888A19121483DD070A0638CCDDD0FEFC929C94C5728CBCF5500DBA007B2582129B318CC35067343E3DD7C5C2340CE33334E5AC2C87B48BAA52FD0424B499089CB9263D6A3C56E3C8F0E3A883237B0CD3AF44164D6AB672F4E3DB975E8CE9D130C0D4D6A0CFC0C2758FC16DC73E50ECD156E6F397678F1B43D36BB52D5CC190C33981C1C64F0851A93681BA3D91E06C6D72E6B6E4E4E4B79F8C099AFA167C55FAF052A0E0D5F1785651D6C6610101039F6804D97010007F695FA",
);
const DB_KEY_7 = "MIIBtzCCASwGByqGSM44BAEwggEfAoGBAKsxIEiJCZc06VVXLYGXeFd0BimYRSXau5N32f6KNjiwtSyQf3cN4IUCMKFATbDvL6x1ePIlF76BmfVQDlpFoNNdROl10sRuAcAO1hUyG/CpAribj7QllmwC0zZGBKS1qy60lt3k5YZ6B7wS/1pWZE4NXYwGhUGW39/BXUJiBDINAhUA6NlAf4jxLoZspMAU8cwaQpMhaa8CgYEAoecuCMxsMYx7PMQ7Mndly5W7KUc45GoQSyjWGd+SCqvCSUm/+lKRgTP4R4lV483JvBVoCiiDlZoAzUviMLbiPpO1LBm/iefw1rgBNDEKsHhYKjEaJ4PYjUhtpECAi3alPfhhV5s9cTBp31WyOuoAyTBGH/m/zlKJzCANILwI0zsDgYQAAoGAQfue3cHIUKChPyZTbpH0TJorOiSMAmKHw9o9Uix/6r0rhevupx1T0Isc40k67NNnLK60LF6nba+SPTlkk1GBTmkd2x9w1013z+c3eqkaHZq2dYNNRbbvm2d3H3BNNeF7MjJPR0n8k2QNSU+SaoXUAaWUc8FyEuL+qouaP9qrSH0="; // gitleaks:allow (public key from UIC's public list)

const keysWith = (ref, algorithm, publicKey) => new Map([[ref, [{ algorithm, publicKey }]]]);
const spki = key => key.export({ type: "spki", format: "der" }).toString("base64");

test("verifies a real DB ticket barcode (version 1, DSA 1024/SHA-1)", async () => {
    const keys = keysWith("1080/7", "SHA1withDSA(1024,160)", DB_KEY_7);
    const genuine = barcode({ version: "01", key: "00007", signature: DB_SAMPLE_SIGNATURE, data: DB_SAMPLE_DATA });
    assert.equal(await verifyUICBarcode(genuine, keys), true);

    // One changed byte in the ticket data, another key ID, another issuer.
    const altered = Uint8Array.from(DB_SAMPLE_DATA);
    altered[100] ^= 1;
    assert.equal(await verifyUICBarcode(barcode({ version: "01", key: "00007", signature: DB_SAMPLE_SIGNATURE, data: altered }), keys), false);
    assert.equal(await verifyUICBarcode(barcode({ version: "01", key: "00008", signature: DB_SAMPLE_SIGNATURE, data: DB_SAMPLE_DATA }), keys), false);
    assert.equal(await verifyUICBarcode(barcode({ version: "01", issuer: "1081", key: "00007", signature: DB_SAMPLE_SIGNATURE, data: DB_SAMPLE_DATA }), keys), false);
});

test("verifies version 2 barcodes with DSA 2048/SHA-256, raw and DER", async () => {
    const { publicKey, privateKey } = generateKeyPairSync("dsa", { modulusLength: 2048, divisorLength: 256 });
    const data = ascii("x\x9c some compressed ticket data");
    const keys = keysWith("1080/12", "SHA256withDSA(2048,256)", spki(publicKey));
    const raw = sign("sha256", data, { key: privateKey, dsaEncoding: "ieee-p1363" });
    assert.equal(raw.length, 64);
    assert.equal(await verifyUICBarcode(barcode({ signature: raw, data }), keys), true);
    const der = sign("sha256", data, { key: privateKey });
    if (der.length <= 64) assert.equal(await verifyUICBarcode(barcode({ signature: der, data }), keys), true);
    const other = generateKeyPairSync("dsa", { modulusLength: 2048, divisorLength: 256 }).privateKey;
    const forged = sign("sha256", data, { key: other, dsaEncoding: "ieee-p1363" });
    assert.equal(await verifyUICBarcode(barcode({ signature: forged, data }), keys), false);
});

test("verifies DSA with SHA-224 and ECDSA P-256 keys", async () => {
    const data = ascii("x\x9c ticket");
    const dsa = generateKeyPairSync("dsa", { modulusLength: 2048, divisorLength: 224 });
    const dsaKeys = keysWith("1181/1", "SHA224withDSA(2048,224)", spki(dsa.publicKey));
    const dsaSignature = sign("sha224", data, { key: dsa.privateKey });
    assert.equal(await verifyUICBarcode(barcode({ issuer: "1181", key: "00001", signature: dsaSignature, data }), dsaKeys), true);

    const ec = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const ecKeys = keysWith("1181/2", "SHA256withECDSA", spki(ec.publicKey));
    const ecSignature = sign("sha256", data, { key: ec.privateKey, dsaEncoding: "ieee-p1363" });
    assert.equal(await verifyUICBarcode(barcode({ issuer: "1181", key: "00002", signature: ecSignature, data }), ecKeys), true);
    ecSignature[5] ^= 1;
    assert.equal(await verifyUICBarcode(barcode({ issuer: "1181", key: "00002", signature: ecSignature, data }), ecKeys), false);
});

test("reads only well-formed #UT barcodes", () => {
    const valid = barcode({ signature: new Uint8Array(64), data: ascii("abc") });
    assert.deepEqual(parseUICBarcode(valid)?.signed, ascii("abc"));
    assert.equal(parseUICBarcode(valid)?.key, "1080/12");
    assert.equal(parseUICBarcode(ascii("Hallo")), null);
    assert.equal(parseUICBarcode(ascii("#UT03108000012")), null);
    assert.equal(parseUICBarcode(valid.subarray(0, valid.length - 1)), null, "data shorter than its length");
    assert.deepEqual(messageBytes("#UTÿ"), Uint8Array.of(0x23, 0x55, 0x54, 0xff));
    assert.equal(messageBytes("#UT€"), null);
});

test("reads UIC's key list", () => {
    const keys = parseKeyList(`<?xml version="1.0"?><keys>
        <key><issuerName>Deutsche Bahn AG</issuerName><issuerCode>1080</issuerCode><signatureAlgorithm>SHA1withDSA(1024,160)</signatureAlgorithm><id>7</id><publicKey>
          ${DB_KEY_7}
        </publicKey><keyForged/></key>
        <key><issuerCode>1080</issuerCode><signatureAlgorithm>DSA1024</signatureAlgorithm><id>00009</id><publicKey>AAAA</publicKey><keyForged>true</keyForged></key>
        <key><issuerCode>3076</issuerCode><id>am013</id><publicKey>BBBB</publicKey><keyForged/></key>
    </keys>`);
    assert.deepEqual([...keys.keys()], ["1080/7", "3076/AM013"]);
    assert.equal(keys.get("1080/7")[0].publicKey, DB_KEY_7);
    assert.equal(keyRef("1080", "00007"), "1080/7");
    assert.equal(keyRef("0080", "AM013"), "80/AM013");
});

test("picks the hash from UIC's algorithm texts", () => {
    assert.equal(hashName("SHA1withDSA(1024,160)", 160), "SHA-1");
    assert.equal(hashName("SHA1-DSA (1024)", 160), "SHA-1");
    assert.equal(hashName("DSA_SHA1 (1024)", 160), "SHA-1");
    assert.equal(hashName("DSA1024", 160), "SHA-1");
    assert.equal(hashName("SHA224withDSA(2048,224)", 224), "SHA-224");
    assert.equal(hashName("SHA256withDSA", 256), "SHA-256");
    assert.equal(hashName("SHA256withECDSA", 256), "SHA-256");
});

test("downloads the key list once a day and falls back to the last copy", async () => {
    resetKeyListMemory();
    const xml = `<keys><key><issuerCode>1080</issuerCode><id>7</id><publicKey>${DB_KEY_7}</publicKey></key></keys>`;
    let calls = 0;
    const fetch = async url => {
        calls++;
        assert.equal(url, KEY_LIST_URL);
        return new Response(xml, { status: 200 });
    };
    const now = Date.UTC(2026, 9, 1);
    assert.equal((await loadKeyList({ fetch, now })).size, 1);
    await loadKeyList({ fetch, now: now + 60_000 });
    assert.equal(calls, 1);

    const failing = async () => { throw new Error("offline"); };
    assert.equal((await loadKeyList({ fetch: failing, now: now + 2 * 86_400_000 })).size, 1, "stale copy");
    resetKeyListMemory();
    await assert.rejects(loadKeyList({ fetch: failing, now }));
    await assert.rejects(loadKeyList({ fetch: async () => new Response("<keys/>"), now }), "empty list");
    resetKeyListMemory();
});
