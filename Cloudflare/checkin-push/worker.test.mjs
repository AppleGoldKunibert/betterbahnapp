import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { TRANSLATIONS } from "../shared/apns.mjs";
import { signToken, toBase64 } from "../shared/appattest.mjs";
import { IDLE_RENEWAL, UNUSED, loginAAD, maintainLogins } from "./logins.mjs";
import { checkedIn, decryptTokens, handleRequest, notification, ownCheckinNotification, parseKinds, processDueSubscriptions, signProviderToken, WEBHOOK_PATH } from "./worker.mjs";

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
            async run() { const { changes } = db.prepare(sql).run(...this.values); return { success: true, meta: { changes } }; },
        };
        return statement;
    }
    rows() { return this.db.prepare("SELECT * FROM subscriptions").all(); }
    logins() { return this.db.prepare("SELECT * FROM logins").all(); }
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

/// Träwelling and APNs stand-in: answers by URL and records each request. Like Cloudflare's `fetch`, it
/// refuses to be called as a method of another object ("Illegal invocation").
function fakeUpstream(routes) {
    const calls = [];
    const fetch = async function (url, init = {}) {
        if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
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
    return { "X-BetterBahn-Token": await signToken({ t: "a", kid: "key-1", exp: Math.floor(now / 1000) + 3 * 24 * 3600 }, secret) };
}

async function request(env, path, method, body, upstream, headers, at = now) {
    return handleRequest(new Request(`https://betterbahn-push.example${path}`, {
        method, headers: { "Content-Type": "application/json", ...(headers ?? await attest()) }, body: JSON.stringify(body),
    }), env, at, upstream);
}

async function subscribed(env, upstream = fakeUpstream({ "oauth/token": tokenAnswer() }), kinds) {
    const response = await request(env, "/subscriptions", "POST", { code: "the-code", codeVerifier: verifier, deviceToken, sandbox: false, userId: 1, kinds }, upstream);
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
    // The app shows these in the device's language.
    const alert = notification(status(1)).aps.alert;
    assert.equal(alert["title-loc-key"], "%@ ist eingecheckt");
    assert.deepEqual(alert["title-loc-args"], [alert.title.replace(" ist eingecheckt", "")]);
    assert.equal(alert["loc-key"], undefined);
});

function liked(id, statusID = 30, liker = { id: 3, username: "anna", name: "Anna" }) {
    return {
        id, type: "StatusLiked",
        data: {
            like: { id: 1 }, status: { id: statusID }, liker,
            trip: { origin: { id: 1, name: "Köln Hbf" }, destination: { id: 2, name: "Bonn Hbf" }, lineName: "RE 5" },
        },
    };
}

function joined(id, statusID = 40) {
    return {
        id, type: "UserJoinedConnection",
        data: { status: { id: statusID }, checkin: { linename: "RE 5", origin: "Köln Hbf", destination: "Bonn Hbf" }, user: { id: 4, username: "bob", name: "Bob" } },
    };
}

test("keeps the kinds asked for and refuses unknown or none", async () => {
    assert.deepEqual(parseKinds(["companions", "followed", "likes", "likes"]), ["followed", "likes", "companions"]);
    assert.equal(parseKinds([]), null);
    assert.equal(parseKinds(["mentions"]), null);
    assert.equal(parseKinds("likes"), null);

    const env = await environment();
    const body = { code: "the-code", codeVerifier: verifier, deviceToken, userId: 1 };
    const upstream = fakeUpstream({ "oauth/token": tokenAnswer() });
    assert.equal((await request(env, "/subscriptions", "POST", { ...body, kinds: [] }, upstream)).status, 400);
    const { id, secret: subscriptionSecret } = await subscribed(env, upstream, ["likes"]);
    assert.equal(env.DB.rows()[0].kinds, '["likes"]');
    assert.equal((await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken, kinds: ["nope"] })).status, 400);
    // Without kinds (apps before #447) they stay as they are.
    assert.equal((await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken })).status, 200);
    assert.equal(env.DB.rows()[0].kinds, '["likes"]');
});

test("notifies likes and fellow travellers once, only the kinds turned on, and not on the first look", async () => {
    const env = await environment();
    await subscribed(env, undefined, ["likes", "companions"]);
    let items = [liked("n1")];
    const pushes = [];
    const upstream = fakeUpstream({
        "api/v1/notifications": () => ({ body: { data: items } }),
        "push.apple.com": (url, init) => { pushes.push(init); return { body: {} }; },
    });

    await processDueSubscriptions(env, now, upstream);
    assert.equal(pushes.length, 0);
    assert.ok(!upstream.calls.some(call => call.url.includes("dashboard")));
    assert.deepEqual(JSON.parse(env.DB.rows()[0].notified), ["n1"]);

    items = [joined("n3"), { id: "n2", type: "UserFollowed", data: {} }, liked("n4", 31), ...items];
    await processDueSubscriptions(env, now + 60000, upstream);
    assert.deepEqual(pushes.map(init => JSON.parse(init.body).aps.alert.title), ["Anna gefällt dein Check-in", "Bob fährt mit dir"]);
    const [like, companion] = pushes.map(init => JSON.parse(init.body));
    assert.equal(like.ownStatusID, 31);
    assert.equal(like.aps.alert.body, "RE 5: Köln Hbf → Bonn Hbf");
    assert.equal(companion.companionStatusID, 40);
    assert.equal(pushes[1].headers["apns-collapse-id"], "followed-40");

    await processDueSubscriptions(env, now + 120000, upstream);
    assert.equal(pushes.length, 2);
    assert.deepEqual(JSON.parse(env.DB.rows()[0].notified), ["n1", "n4", "n2", "n3"]);
});

test("leaves out the kinds turned off and starts over when one is turned on again", async () => {
    const env = await environment();
    const { id, secret: subscriptionSecret } = await subscribed(env, undefined, ["followed", "companions"]);
    env.DB.db.prepare("UPDATE subscriptions SET known = '[]', notified = '[]'").run();
    const pushes = [];
    const upstream = fakeUpstream({
        "api/v1/dashboard": { body: { data: [] } },
        "api/v1/notifications": { body: { data: [liked("n1"), joined("n2")] } },
        "push.apple.com": (url, init) => { pushes.push(JSON.parse(init.body)); return { body: {} }; },
    });
    await processDueSubscriptions(env, now, upstream);
    assert.deepEqual(pushes.map(push => push.aps.alert.title), ["Bob fährt mit dir"]);
    assert.deepEqual(JSON.parse(env.DB.rows()[0].notified), ["n2", "n1"]);

    // Adding likes keeps what was seen; turning followed off and on again starts it over.
    await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken, kinds: ["likes", "companions"] });
    assert.deepEqual(JSON.parse(env.DB.rows()[0].notified), ["n2", "n1"]);
    await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken, kinds: ["followed", "likes"] });
    assert.equal(env.DB.rows()[0].known, null);
    assert.deepEqual(JSON.parse(env.DB.rows()[0].notified), ["n2", "n1"]);
    await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken, kinds: ["followed"] });
    await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken, kinds: ["followed", "likes"] });
    assert.equal(env.DB.rows()[0].notified, null);
});

test("a login without read-notifications still gets followed check-ins", async () => {
    const env = await environment();
    await subscribed(env, undefined, ["followed", "likes"]);
    env.DB.db.prepare("UPDATE subscriptions SET known = '[]', notified = '[]'").run();
    const pushes = [];
    await processDueSubscriptions(env, now, fakeUpstream({
        "api/v1/dashboard": { body: { data: [status(50)] } },
        "api/v1/notifications": { status: 403, body: { message: "Invalid scope(s) provided." } },
        "push.apple.com": (url, init) => { pushes.push(JSON.parse(init.body)); return { body: {} }; },
    }));
    assert.deepEqual(pushes.map(push => push.followedStatusID), [50]);
    assert.equal(env.DB.rows().length, 1);
    assert.deepEqual(JSON.parse(env.DB.rows()[0].notified), []);
});

test("names who liked or joined, with a fallback for missing names", () => {
    assert.equal(ownCheckinNotification(liked("n", 1, { username: "anna" }), ["likes"]).payload.aps.alert.title, "@anna gefällt dein Check-in");
    assert.equal(ownCheckinNotification(liked("n", 1, null), ["likes"]).payload.aps.alert.title, "Jemand gefällt dein Check-in");
    assert.equal(ownCheckinNotification(liked("n"), ["companions"]), null);
    assert.equal(ownCheckinNotification({ id: "n", type: "StatusLiked", data: {} }, ["likes"]), null);
});

async function signed(body, secret) {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))).toString("hex");
}

async function deliver(env, upstream, { webhookID = 77, secret: webhookSecret = "hook-secret", item = liked("w1"), signature } = {}) {
    const body = JSON.stringify({ event: "notification", notification: item });
    return handleRequest(new Request(`https://betterbahn-push.example${WEBHOOK_PATH}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Trwl-Webhook-Id": String(webhookID), Signature: signature ?? await signed(body, webhookSecret) },
        body,
    }), env, now, upstream);
}

test("writes the notifications in the app's language, else German with the keys iOS translates", () => {
    const english = ownCheckinNotification(liked("n", 1), ["likes"], "en").payload.aps.alert;
    assert.deepEqual(english, { title: "Anna likes your check-in", body: "RE 5: Köln Hbf → Bonn Hbf" });
    assert.equal(notification({ ...status(1), user: null }, "en").aps.alert.title, "Someone checked in");
    // An app set to German gets German even on an English iPhone: no keys.
    assert.deepEqual(Object.keys(notification(status(1), "de").aps.alert), ["title", "body"]);
    assert.equal(notification(status(1)).aps.alert["title-loc-key"], "%@ ist eingecheckt");
});

test("keeps the app's language and sends in it", async () => {
    const env = await environment();
    const { id, secret: subscriptionSecret } = await subscribed(env, undefined, ["likes"]);
    assert.equal(env.DB.rows()[0].language, null);
    await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken, kinds: ["likes"], language: "en" });
    assert.equal(env.DB.rows()[0].language, "en");
    // Without it (apps before #479) it stays; an unknown one is none.
    await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken, kinds: ["likes"] });
    assert.equal(env.DB.rows()[0].language, "en");
    env.DB.db.prepare("UPDATE subscriptions SET notified = '[]'").run();
    const pushes = [];
    await processDueSubscriptions(env, now, fakeUpstream({
        "api/v1/notifications": { body: { data: [liked("n1")] } },
        "push.apple.com": (url, init) => { pushes.push(JSON.parse(init.body)); return { body: {} }; },
    }));
    assert.deepEqual(pushes.map(push => push.aps.alert.title), ["Anna likes your check-in"]);
    await request(env, `/subscriptions/${id}`, "PUT", { secret: subscriptionSecret, deviceToken, kinds: ["likes"], language: "fr" });
    assert.equal(env.DB.rows()[0].language, null);
});

test("the translations match the app's string catalog", () => {
    const catalog = JSON.parse(readFileSync(new URL("../../BetterBahn/Localizable.xcstrings", import.meta.url), "utf8")).strings;
    for (const [language, texts] of Object.entries(TRANSLATIONS)) {
        for (const [key, value] of Object.entries(texts)) {
            assert.equal(catalog[key]?.localizations?.[language]?.stringUnit?.value, value, key);
        }
    }
});

test("offers Träwelling's webhook to the login only while it is turned on", async () => {
    const options = async (extra) => (await handleRequest(new Request("https://betterbahn-push.example/login-options"), await environment(extra), now)).json();
    assert.deepEqual(await options({}), { authorize: {} });
    assert.deepEqual(await options({ TRAEWELLING_WEBHOOKS: "true" }), {
        authorize: { trwl_webhook_url: "https://betterbahn-push.example/traewelling/webhook", trwl_webhook_events: "notification" },
    });
});

test("pushes a like from the webhook at once, only with a valid signature, and not again on the next look", async () => {
    const env = await environment();
    const signUp = fakeUpstream({ "oauth/token": { body: { ...tokenAnswer().body, webhook: { id: 77, secret: "hook-secret", url: "x" } } } });
    await subscribed(env, signUp, ["likes"]);
    const [row] = env.DB.rows();
    assert.equal(row.webhook_id, 77);
    assert.ok(!row.webhook.includes("hook-secret"));
    env.DB.db.prepare("UPDATE subscriptions SET notified = '[]'").run();

    const pushes = [];
    const upstream = fakeUpstream({
        "api/v1/notifications": { body: { data: [liked("w1")] } },
        "push.apple.com": (url, init) => { pushes.push(JSON.parse(init.body)); return { body: {} }; },
    });
    assert.equal((await deliver(env, upstream, { signature: "00".repeat(32) })).status, 401);
    assert.equal((await deliver(env, upstream, { webhookID: 78 })).status, 410);
    assert.equal((await deliver(env, upstream, { item: joined("w2") })).status, 200);
    assert.equal(pushes.length, 0);

    assert.equal((await deliver(env, upstream)).status, 200);
    assert.deepEqual(pushes.map(push => push.ownStatusID), [30]);
    assert.deepEqual(JSON.parse(env.DB.rows()[0].notified), ["w1"]);
    await deliver(env, upstream);
    await processDueSubscriptions(env, now, upstream);
    assert.equal(pushes.length, 1);
});

test("ends the webhook with the subscription", async () => {
    const env = await environment();
    const signUp = fakeUpstream({ "oauth/token": { body: { ...tokenAnswer().body, webhook: { id: 77, secret: "hook-secret", url: "x" } } } });
    const { id, secret: subscriptionSecret } = await subscribed(env, signUp, ["likes"]);
    const upstream = fakeUpstream({ "api/v1/webhooks/77": { body: {} }, "auth/logout": { body: {} } });
    assert.equal((await request(env, `/subscriptions/${id}`, "DELETE", { secret: subscriptionSecret }, upstream)).status, 204);
    assert.deepEqual(upstream.calls.map(call => [call.init.method, new URL(call.url).pathname]),
        [["DELETE", "/api/v1/webhooks/77"], ["POST", "/api/v1/auth/logout"]]);
    assert.equal((await deliver(env, upstream)).status, 410);
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

// MARK: - The app's login (#452)

async function loggedIn(env, upstream = fakeUpstream({ "oauth/token": tokenAnswer() })) {
    const response = await request(env, "/logins", "POST", { code: "the-code", codeVerifier: verifier }, upstream);
    assert.equal(response.status, 201);
    return response.json();
}

test("signs in with the authorization code and hands out the access token, keeping the login encrypted", async () => {
    const env = await environment();
    const upstream = fakeUpstream({ "oauth/token": tokenAnswer() });
    const login = await loggedIn(env, upstream);
    assert.match(login.id, /^[0-9a-f]{32}$/);
    assert.equal(login.accessToken, "access-1");
    assert.equal(login.expiresAt, now / 1000 + 3600);
    assert.equal(login.readsNotifications, true);
    assert.equal(new URLSearchParams(upstream.calls[0].init.body).get("grant_type"), "authorization_code");

    const [row] = env.DB.logins();
    assert.ok(!row.tokens.includes("refresh-1"));
    assert.equal((await decryptTokens(row.tokens, loginAAD(login.id), tokenKey)).refresh, "refresh-1");

    // Fetching again changes nothing while the token has time left.
    const later = now + 30 * 60 * 1000;
    const response = await request(env, `/logins/${login.id}/token`, "POST", { secret: login.secret }, upstream, undefined, later);
    assert.deepEqual(await response.json(), { accessToken: "access-1", expiresAt: now / 1000 + 3600, readsNotifications: true });
    assert.equal(upstream.calls.length, 1);
    assert.equal(env.DB.logins()[0].used, later / 1000);
    assert.equal((await request(env, `/logins/${login.id}/token`, "POST", { secret: "wrong" }, upstream)).status, 404);
});

test("takes over the refresh token of an app from before and renews it at once", async () => {
    const env = await environment();
    const upstream = fakeUpstream({ "oauth/token": tokenAnswer("access-2", "refresh-2") });
    const response = await request(env, "/logins", "POST", { refreshToken: "the-apps-refresh" }, upstream);
    assert.equal(response.status, 201);
    const login = await response.json();
    assert.equal(login.accessToken, "access-2");
    assert.equal(login.readsNotifications, false);
    const form = new URLSearchParams(upstream.calls[0].init.body);
    assert.equal(form.get("grant_type"), "refresh_token");
    assert.equal(form.get("refresh_token"), "the-apps-refresh");
    assert.equal((await decryptTokens(env.DB.logins()[0].tokens, loginAAD(login.id), tokenKey)).refresh, "refresh-2");

    const rejected = fakeUpstream({ "oauth/token": { status: 400, body: { error: "invalid_grant" } } });
    const refused = await request(env, "/logins", "POST", { refreshToken: "used-up" }, rejected);
    assert.equal(refused.status, 400);
    assert.deepEqual(await refused.json(), { error: "invalid_grant" });
    assert.equal(env.DB.logins().length, 1);
});

test("renews in the token's last 15 minutes and saves the new one before answering", async () => {
    const env = await environment();
    const login = await loggedIn(env);
    const upstream = fakeUpstream({ "oauth/token": tokenAnswer("access-2", "refresh-2") });
    const at = now + 50 * 60 * 1000;
    const response = await request(env, `/logins/${login.id}/token`, "POST", { secret: login.secret }, upstream, undefined, at);
    assert.equal((await response.json()).accessToken, "access-2");
    assert.equal(new URLSearchParams(upstream.calls[0].init.body).get("refresh_token"), "refresh-1");
    const [row] = env.DB.logins();
    assert.equal(row.renewing, null);
    assert.equal(row.renewed, at / 1000);
    assert.equal((await decryptTokens(row.tokens, loginAAD(login.id), tokenKey)).refresh, "refresh-2");
});

test("renews a token Träwelling refused even with time left, but not an older one", async () => {
    const env = await environment();
    const login = await loggedIn(env);
    const upstream = fakeUpstream({ "oauth/token": tokenAnswer("access-2", "refresh-2") });
    const old = await request(env, `/logins/${login.id}/token`, "POST", { secret: login.secret, rejected: "access-0" }, upstream);
    assert.equal((await old.json()).accessToken, "access-1");
    assert.equal(upstream.calls.length, 0);
    const renewed = await request(env, `/logins/${login.id}/token`, "POST", { secret: login.secret, rejected: "access-1" }, upstream);
    assert.equal((await renewed.json()).accessToken, "access-2");
});

test("ends the login and its notifications when Träwelling refuses the renewal", async () => {
    const env = await environment();
    const login = await loggedIn(env);
    await request(env, "/subscriptions", "POST", { loginId: login.id, loginSecret: login.secret, deviceToken, userId: 1 }, fakeUpstream({}));
    assert.equal(env.DB.rows().length, 1);
    const upstream = fakeUpstream({ "oauth/token": { status: 400, body: { error: "invalid_grant" } } });
    const response = await request(env, `/logins/${login.id}/token`, "POST", { secret: login.secret }, upstream, undefined, now + 2 * 3600 * 1000);
    assert.equal(response.status, 404);
    assert.equal(env.DB.logins().length, 0);
    assert.equal(env.DB.rows().length, 0);
});

test("keeps the login when Träwelling doesn't answer, and lets the next request renew", async () => {
    const env = await environment();
    const login = await loggedIn(env);
    const at = now + 2 * 3600 * 1000;
    const down = await request(env, `/logins/${login.id}/token`, "POST", { secret: login.secret }, fakeUpstream({ "oauth/token": { status: 503 } }), undefined, at);
    assert.equal(down.status, 502);
    assert.equal(env.DB.logins()[0].renewing, null);
    const up = await request(env, `/logins/${login.id}/token`, "POST", { secret: login.secret }, fakeUpstream({ "oauth/token": tokenAnswer("access-2", "refresh-2") }), undefined, at);
    assert.equal((await up.json()).accessToken, "access-2");
});

test("only one request renews: another waits for its new token instead of using the refresh token twice", async () => {
    const env = await environment();
    const login = await loggedIn(env);
    const at = now + 2 * 3600 * 1000;
    // Another request holds the renewal; it saves its new token while this one waits.
    env.DB.db.prepare("UPDATE logins SET renewing = ?").run(at / 1000 + 30);
    const { encryptTokens } = await import("./logins.mjs");
    const fresh = await encryptTokens({ access: "access-2", refresh: "refresh-2", expires: at / 1000 + 3600 }, loginAAD(login.id), tokenKey);
    let waits = 0;
    const sleep = async () => { if (++waits === 2) env.DB.db.prepare("UPDATE logins SET tokens = ?, renewing = NULL").run(fresh); };
    const upstream = fakeUpstream({ "oauth/token": tokenAnswer("never", "never") });
    const response = await handleRequest(new Request(`https://betterbahn-push.example/logins/${login.id}/token`, {
        method: "POST", headers: await attest(), body: JSON.stringify({ secret: login.secret }),
    }), env, at, { fetch: upstream.fetch, sleep });
    assert.equal((await response.json()).accessToken, "access-2");
    assert.equal(upstream.calls.length, 0);

    // Nothing comes: "busy", and the stored login is left alone.
    env.DB.db.prepare("UPDATE logins SET renewing = ?").run(at / 1000 + 3600 + 30);
    const busy = await handleRequest(new Request(`https://betterbahn-push.example/logins/${login.id}/token`, {
        method: "POST", headers: await attest(), body: JSON.stringify({ secret: login.secret }),
    }), env, at + 3600 * 1000, { fetch: upstream.fetch, sleep: async () => {} });
    assert.equal(busy.status, 503);
    assert.equal(upstream.calls.length, 0);
});

test("signs in again in place and ends the old Träwelling login", async () => {
    const env = await environment();
    const handedOver = await (await request(env, "/logins", "POST", { refreshToken: "old" }, fakeUpstream({ "oauth/token": tokenAnswer() }))).json();
    assert.equal(handedOver.readsNotifications, false);
    const upstream = fakeUpstream({ "oauth/token": tokenAnswer("access-2", "refresh-2"), "auth/logout": { body: {} } });
    const response = await request(env, `/logins/${handedOver.id}`, "PUT", { secret: handedOver.secret, code: "new-code", codeVerifier: verifier }, upstream);
    assert.deepEqual(await response.json(), { accessToken: "access-2", expiresAt: now / 1000 + 3600, readsNotifications: true });
    assert.equal(upstream.calls[1].init.headers.Authorization, "Bearer access-1");
    assert.equal(env.DB.logins().length, 1);
});

test("logging out ends the Träwelling login and the notifications running on it", async () => {
    const env = await environment();
    const login = await loggedIn(env);
    await request(env, "/subscriptions", "POST", { loginId: login.id, loginSecret: login.secret, deviceToken, userId: 1 }, fakeUpstream({}));
    assert.equal((await request(env, `/logins/${login.id}`, "DELETE", { secret: "wrong" }, fakeUpstream({}))).status, 404);
    const upstream = fakeUpstream({ "auth/logout": { body: {} } });
    assert.equal((await request(env, `/logins/${login.id}`, "DELETE", { secret: login.secret }, upstream)).status, 204);
    assert.equal(upstream.calls[0].init.headers.Authorization, "Bearer access-1");
    assert.equal(env.DB.logins().length, 0);
    assert.equal(env.DB.rows().length, 0);
});

test("notifications read with the app's login, renew it there and leave it when turned off", async () => {
    const env = await environment();
    const login = await loggedIn(env);
    assert.equal((await request(env, "/subscriptions", "POST", { loginId: login.id, loginSecret: "wrong", deviceToken, userId: 1 }, fakeUpstream({}))).status, 404);
    const response = await request(env, "/subscriptions", "POST", { loginId: login.id, loginSecret: login.secret, deviceToken, userId: 1 }, fakeUpstream({}));
    assert.equal(response.status, 201);
    const subscription = await response.json();
    assert.equal(env.DB.rows()[0].login_id, login.id);
    assert.equal(env.DB.rows()[0].tokens, "");

    // Träwelling refuses the hour-old token: the login is renewed in its one place.
    const upstream = fakeUpstream({
        "api/v1/dashboard": (url, init) => init.headers.Authorization === "Bearer access-2" ? { body: { data: [] } } : { status: 401 },
        "oauth/token": tokenAnswer("access-2", "refresh-2"),
    });
    await processDueSubscriptions(env, now, upstream);
    assert.deepEqual(upstream.calls.map(call => call.url.replace("https://traewelling.de/", "")), ["api/v1/dashboard", "oauth/token", "api/v1/dashboard"]);
    assert.equal((await decryptTokens(env.DB.logins()[0].tokens, loginAAD(login.id), tokenKey)).refresh, "refresh-2");
    assert.equal(env.DB.rows()[0].known, "[]");

    const logout = fakeUpstream({ "auth/logout": { body: {} } });
    assert.equal((await request(env, `/subscriptions/${subscription.id}`, "DELETE", { secret: subscription.secret }, logout)).status, 204);
    assert.equal(logout.calls.length, 0);
    assert.equal(env.DB.logins().length, 1);
});

test("renews logins nobody renewed for 20 days and ends those no device fetched for 180", async () => {
    const env = await environment();
    const kept = await loggedIn(env);
    const unused = await loggedIn(env);
    const withNotifications = await loggedIn(env);
    await request(env, "/subscriptions", "POST", { loginId: withNotifications.id, loginSecret: withNotifications.secret, deviceToken, userId: 1 }, fakeUpstream({}));
    const later = now + (IDLE_RENEWAL + 3600) * 1000;
    env.DB.db.prepare("UPDATE logins SET used = ? WHERE id != ?").run(now / 1000 - UNUSED, kept.id);
    env.DB.db.prepare("UPDATE logins SET used = ? WHERE id = ?").run(later / 1000, kept.id);

    const upstream = fakeUpstream({ "oauth/token": tokenAnswer("access-2", "refresh-2") });
    await maintainLogins(env, later, upstream);
    const ids = env.DB.logins().map(row => row.id).sort();
    assert.deepEqual(ids, [kept.id, withNotifications.id].sort());
    assert.equal(upstream.calls.length, 2);
    assert.ok(env.DB.logins().every(row => row.renewed === later / 1000));

    await maintainLogins(env, later + 60000, upstream);
    assert.equal(upstream.calls.length, 2);
});

test("the app's login keeps Träwelling's webhook and pushes its likes to every device signed up on it", async () => {
    const env = await environment();
    const withHook = fakeUpstream({ "oauth/token": { body: { ...tokenAnswer().body, webhook: { id: 77, secret: "hook-secret", url: "x" } } } });
    const login = await loggedIn(env, withHook);
    const [row] = env.DB.logins();
    assert.equal(row.webhook_id, 77);
    assert.ok(!row.webhook.includes("hook-secret"));
    assert.equal((await decryptTokens(row.tokens, loginAAD(login.id), tokenKey)).webhook, undefined);

    const other = "cd".repeat(32);
    for (const token of [deviceToken, other]) {
        await request(env, "/subscriptions", "POST", { loginId: login.id, loginSecret: login.secret, deviceToken: token, userId: 1, kinds: ["likes"] }, fakeUpstream({}));
    }
    env.DB.db.prepare("UPDATE subscriptions SET notified = '[]'").run();
    const pushes = [];
    const upstream = fakeUpstream({ "push.apple.com": (url) => { pushes.push(url); return { body: {} }; } });
    assert.equal((await deliver(env, upstream, { secret: "wrong" })).status, 401);
    assert.equal((await deliver(env, upstream)).status, 200);
    assert.deepEqual(pushes.sort(), [deviceToken, other].map(token => `https://api.push.apple.com/3/device/${token}`).sort());
    assert.ok(env.DB.rows().every(subscription => subscription.notified === '["w1"]'));

    // Logging out deletes the webhook at Träwelling.
    const logout = fakeUpstream({ "api/v1/webhooks/77": { body: {} }, "auth/logout": { body: {} } });
    assert.equal((await request(env, `/logins/${login.id}`, "DELETE", { secret: login.secret }, logout)).status, 204);
    assert.deepEqual(logout.calls.map(call => [call.init.method, new URL(call.url).pathname]),
        [["DELETE", "/api/v1/webhooks/77"], ["POST", "/api/v1/auth/logout"]]);
    assert.equal((await deliver(env, upstream)).status, 410);
});
