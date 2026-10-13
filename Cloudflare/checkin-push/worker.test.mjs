import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { signToken, toBase64 } from "../shared/appattest.mjs";
import { checkedIn, decryptTokens, handleRequest, notification, processDueSubscriptions, signProviderToken } from "./worker.mjs";

const secret = "test-secret";
const schema = readFileSync(new URL("./schema.sql", import.meta.url), "utf8");
const tokenKey = toBase64(new Uint8Array(32).fill(7));
const deviceToken = "ab".repeat(32);
const verifier = "v".repeat(43);
const now = Date.parse("2026-10-13T12:00:00Z");

/// D1's API on an in-memory SQLite database.
class FakeD1 {
    constructor() {
        this.db = new DatabaseSync(":memory:");
        this.db.exec(schema);
    }
    prepare(sql) {
        const db = this.db;
        const statement = {
            values: [],
            bind(...values) { return { ...statement, values }; },
            async all() { return { results: db.prepare(sql).all(...this.values) }; },
            async first() { return db.prepare(sql).get(...this.values) ?? null; },
            async run() { db.prepare(sql).run(...this.values); return { success: true }; },
        };
        return statement;
    }
    rows() { return this.db.prepare("SELECT * FROM subscriptions").all(); }
}

let apnsKey;
async function environment(extra = {}) {
    if (!apnsKey) {
        const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
        const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
        apnsKey = { pem: `-----BEGIN PRIVATE KEY-----\n${toBase64(pkcs8)}\n-----END PRIVATE KEY-----`, publicKey: pair.publicKey };
    }
    return {
        DB: new FakeD1(), TOKEN_SECRET: secret, TOKEN_KEY: tokenKey, INTERVAL_MINUTES: "1",
        APNS_KEY: apnsKey.pem, APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123", APNS_TOPIC: "de.goldkunibert.BetterBahn",
        TRAEWELLING_CLIENT_ID: "406", TRAEWELLING_REDIRECT_URI: "https://example/callback", ...extra,
    };
}

/// Träwelling and APNs stand-in: answers by URL and records each request.
function fakeUpstream(routes) {
    const calls = [];
    const fetch = async (url, init = {}) => {
        calls.push({ url, init });
        const answer = Object.entries(routes).find(([prefix]) => url.includes(prefix))?.[1];
        if (!answer) return new Response("", { status: 404 });
        const { status = 200, body = {} } = typeof answer === "function" ? answer(url, init) : answer;
        return new Response(JSON.stringify(body), { status });
    };
    return { fetch, calls };
}

const tokenAnswer = (access = "access-1", refresh = "refresh-1") => ({ body: { access_token: access, refresh_token: refresh, expires_in: 3600 } });

function status(id, { user = { id: 2, displayName: "Erika" }, departure = "2026-10-13T11:50:00Z", arrival = "2026-10-13T13:00:00Z", line = "ICE 1095" } = {}) {
    return {
        id, user,
        checkin: {
            lineName: line,
            origin: { name: "München Hbf", departurePlanned: departure },
            destination: { name: "Frankfurt(Main)Hbf", arrivalPlanned: arrival },
        },
    };
}

async function attest() {
    return { "X-BetterBahn-Token": await signToken({ t: "a", kid: "key-1", exp: Math.floor(now / 1000) + 3600 }, secret) };
}

async function request(env, path, method, body, upstream, headers) {
    return handleRequest(new Request(`https://betterbahn-push.example${path}`, {
        method, headers: { "Content-Type": "application/json", ...(headers ?? await attest()) }, body: JSON.stringify(body),
    }), env, now, upstream);
}

async function subscribed(env, upstream = fakeUpstream({ "oauth/token": tokenAnswer() })) {
    const response = await request(env, "/subscriptions", "POST", { code: "the-code", codeVerifier: verifier, deviceToken, sandbox: false, userId: 1 }, upstream);
    assert.equal(response.status, 201);
    return response.json();
}

test("signs up with the authorization code and keeps only the encrypted login", async () => {
    const env = await environment();
    const upstream = fakeUpstream({ "oauth/token": tokenAnswer() });
    const { id, secret: subscriptionSecret } = await subscribed(env, upstream);
    assert.match(id, /^[0-9a-f]{32}$/);
    assert.match(subscriptionSecret, /^[0-9a-f]{64}$/);

    const form = new URLSearchParams(upstream.calls[0].init.body);
    assert.equal(form.get("grant_type"), "authorization_code");
    assert.equal(form.get("code_verifier"), verifier);
    assert.equal(form.get("redirect_uri"), "https://example/callback");

    const [row] = env.DB.rows();
    assert.equal(row.device_token, deviceToken);
    assert.equal(row.user_id, 1);
    assert.equal(row.known, null);
    assert.ok(!row.tokens.includes("access-1"));
    assert.ok(row.secret_hash !== subscriptionSecret);
    assert.equal((await decryptTokens(row.tokens, id, tokenKey)).refresh, "refresh-1");
});

test("refuses sign-ups without App Attest, with a bad device token or a code Träwelling rejects", async () => {
    const env = await environment();
    const upstream = fakeUpstream({ "oauth/token": { status: 400, body: { error: "invalid_grant" } } });
    const body = { code: "the-code", codeVerifier: verifier, deviceToken, userId: 1 };
    assert.equal((await request(env, "/subscriptions", "POST", body, upstream, {})).status, 401);
    assert.equal((await request(env, "/subscriptions", "POST", { ...body, deviceToken: "nope" }, upstream)).status, 400);
    assert.equal((await request(env, "/subscriptions", "POST", body, upstream)).status, 400);
    assert.equal(env.DB.rows().length, 0);
});

test("updates the device token and ends the subscription only with its secret", async () => {
    const env = await environment();
    const { id, secret: subscriptionSecret } = await subscribed(env);
    const newToken = "cd".repeat(32);
    assert.equal((await request(env, `/subscriptions/${id}`, "PUT", { secret: "wrong", deviceToken: newToken })).status, 404);
    assert.equal((await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken: newToken, sandbox: true })).status, 200);
    assert.equal(env.DB.rows()[0].device_token, newToken);
    assert.equal(env.DB.rows()[0].sandbox, 1);

    const upstream = fakeUpstream({ "auth/logout": { body: {} } });
    assert.equal((await request(env, `/subscriptions/${id}`, "DELETE", { secret: subscriptionSecret }, upstream)).status, 204);
    assert.equal(env.DB.rows().length, 0);
    assert.equal(upstream.calls[0].init.headers.Authorization, "Bearer access-1");
    assert.equal((await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken })).status, 404);
});

test("the first look only remembers, later ones notify each new check-in of others once", async () => {
    const env = await environment();
    await subscribed(env);
    let statuses = [status(10), status(11, { user: { id: 1, displayName: "Ich" } })];
    const pushes = [];
    const upstream = fakeUpstream({
        "api/v1/dashboard": () => ({ body: { data: statuses } }),
        "push.apple.com": (url, init) => { pushes.push({ url, init }); return { body: {} }; },
    });

    assert.equal(await processDueSubscriptions(env, now, upstream), 1);
    assert.equal(pushes.length, 0);
    assert.deepEqual(JSON.parse(env.DB.rows()[0].known), [10]);

    statuses = [status(12), ...statuses];
    await processDueSubscriptions(env, now + 60000, upstream);
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].url, `https://api.push.apple.com/3/device/${deviceToken}`);
    assert.equal(pushes[0].init.headers["apns-topic"], "de.goldkunibert.BetterBahn");
    const payload = JSON.parse(pushes[0].init.body);
    assert.equal(payload.aps.alert.title, "Erika ist eingecheckt");
    assert.equal(payload.followedStatusID, 12);

    await processDueSubscriptions(env, now + 120000, upstream);
    assert.equal(pushes.length, 1);
    assert.deepEqual(JSON.parse(env.DB.rows()[0].known), [10, 12]);
});

test("looks at each subscription only in its own minute", async () => {
    const env = await environment({ INTERVAL_MINUTES: "2" });
    await subscribed(env);
    const upstream = fakeUpstream({ "api/v1/dashboard": { body: { data: [] } } });
    const slot = env.DB.rows()[0].slot;
    const due = Date.parse("2026-10-13T12:00:00Z") + (slot % 2) * 60000;
    assert.equal(await processDueSubscriptions(env, due, upstream), 1);
    assert.equal(await processDueSubscriptions(env, due + 60000, upstream), 0);
});

test("renews an expired login and keeps the new refresh token", async () => {
    const env = await environment();
    const { id } = await subscribed(env);
    const upstream = fakeUpstream({
        "oauth/token": tokenAnswer("access-2", "refresh-2"),
        "api/v1/dashboard": { body: { data: [] } },
    });
    await processDueSubscriptions(env, now + 2 * 3600 * 1000, upstream);
    const form = new URLSearchParams(upstream.calls[0].init.body);
    assert.equal(form.get("grant_type"), "refresh_token");
    assert.equal(form.get("refresh_token"), "refresh-1");
    assert.equal(upstream.calls[1].init.headers.Authorization, "Bearer access-2");
    assert.equal((await decryptTokens(env.DB.rows()[0].tokens, id, tokenKey)).refresh, "refresh-2");
});

test("drops the subscription when Träwelling ended the login or the app is gone", async () => {
    let env = await environment();
    await subscribed(env);
    await processDueSubscriptions(env, now, fakeUpstream({
        "api/v1/dashboard": { status: 401 },
        "oauth/token": { status: 400, body: { error: "invalid_grant" } },
    }));
    assert.equal(env.DB.rows().length, 0);

    env = await environment();
    await subscribed(env);
    env.DB.db.prepare("UPDATE subscriptions SET known = '[]'").run();
    await processDueSubscriptions(env, now, fakeUpstream({
        "api/v1/dashboard": { body: { data: [status(20)] } },
        "push.apple.com": { status: 410, body: { reason: "Unregistered" } },
    }));
    assert.equal(env.DB.rows().length, 0);
});

test("keeps the subscription and tries again when Träwelling or APNs fail", async () => {
    const env = await environment();
    await subscribed(env);
    env.DB.db.prepare("UPDATE subscriptions SET known = '[]'").run();
    await processDueSubscriptions(env, now, fakeUpstream({ "api/v1/dashboard": { status: 503 } }));
    await processDueSubscriptions(env, now, fakeUpstream({
        "api/v1/dashboard": { body: { data: [status(20)] } },
        "push.apple.com": { status: 500, body: { reason: "InternalServerError" } },
    }));
    assert.equal(env.DB.rows().length, 1);
    assert.deepEqual(JSON.parse(env.DB.rows()[0].known), []);
});

test("counts rides under way or leaving within 20 minutes, not ended ones or the user's own", () => {
    const statuses = [
        status(1),
        status(2, { departure: "2026-10-13T12:15:00Z" }),
        status(3, { departure: "2026-10-13T13:00:00Z", arrival: "2026-10-13T14:00:00Z" }),
        status(4, { departure: "2026-10-13T10:00:00Z", arrival: "2026-10-13T11:00:00Z" }),
        status(5, { user: { id: 1, displayName: "Ich" } }),
        { ...status(6), user: null },
        status(1),
    ];
    assert.deepEqual(checkedIn(statuses, 1, now).map(s => s.id), [1, 2]);
});

test("names who checked in and the train from where to where", () => {
    assert.equal(notification(status(1)).aps.alert.body, "ICE 1095: München Hbf → Frankfurt(Main)Hbf");
    assert.equal(notification(status(1, { line: "" })).aps.alert.body, "München Hbf → Frankfurt(Main)Hbf");
    assert.equal(notification({ ...status(1), user: null }).aps.alert.title, "Jemand ist eingecheckt");
});

test("signs the APNs provider token with ES256", async () => {
    await environment();
    const token = await signProviderToken(apnsKey.pem, "KEY123", "TEAM123", 1_700_000_000);
    const [header, claims, signature] = token.split(".");
    const decode = part => JSON.parse(Buffer.from(part, "base64url").toString());
    assert.deepEqual(decode(header), { alg: "ES256", kid: "KEY123" });
    assert.deepEqual(decode(claims), { iss: "TEAM123", iat: 1_700_000_000 });
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, apnsKey.publicKey,
        Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${claims}`));
    assert.ok(valid);
});
