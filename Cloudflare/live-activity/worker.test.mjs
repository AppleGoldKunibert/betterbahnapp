import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { signToken, toBase64 } from "../shared/appattest.mjs";
import { IRIS, categoryOf, changedStop, matchStop, parseStops, parseTime, planPath } from "./iris.mjs";
import { contentState, encodeState, nextRefresh } from "./state.mjs";
import { handleRequest, liveEvents, processDueActivities, sanitizeJourney } from "./worker.mjs";

const secret = "test-secret";
const schema = readFileSync(new URL("./schema.sql", import.meta.url), "utf8");
const fixture = JSON.parse(readFileSync(new URL("../../Packages/BetterBahnKit/Tests/BetterBahnKitTests/Fixtures/live-activity-push.json", import.meta.url), "utf8"));
const T0 = Date.parse("2026-10-17T10:00:00Z") / 1000; // 12:00 in Germany
const m = (minutes) => T0 + minutes * 60;
const REFERENCE_DATE = 978307200;
const id = "0123456789abcdef0123456789abcdef";
const appSecret = "ab".repeat(32);
const pushToken = "cd".repeat(40);

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
    rows() { return this.db.prepare("SELECT * FROM activities").all(); }
}

let apnsKey;
async function environment(extra = {}) {
    if (!apnsKey) {
        const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
        const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
        apnsKey = `-----BEGIN PRIVATE KEY-----\n${toBase64(pkcs8)}\n-----END PRIVATE KEY-----`;
    }
    return {
        DB: new FakeD1(), TOKEN_SECRET: secret, APNS_KEY: apnsKey, APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123",
        APNS_TOPIC: "de.goldkunibert.BetterBahn", ...extra,
    };
}

/// IRIS and APNs stand-in: answers by URL (text, or [status, text]) and records each request. Like Cloudflare's
/// `fetch`, it refuses to be called as a method of another object ("Illegal invocation").
function fakeUpstream(routes) {
    const calls = [];
    const fetch = async function (url, init = {}) {
        if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
        calls.push({ url, init });
        const answer = Object.entries(routes).find(([prefix]) => url.startsWith(prefix))?.[1];
        if (answer === undefined) return new Response("", { status: 404 });
        const [status, body] = Array.isArray(answer) ? answer : [200, typeof answer === "function" ? answer(url, init) : answer];
        return new Response(body, { status });
    };
    fetch.calls = calls;
    fetch.pushes = () => calls.filter(call => call.url.includes("push.apple.com")).map(call => ({ ...call, body: JSON.parse(call.init.body) }));
    return fetch;
}

async function request(method, body, { token = true, path = `/activities/${id}`, now = m(-10) * 1000 } = {}, env) {
    const headers = { "Content-Type": "application/json" };
    if (token) headers["X-BetterBahn-Token"] = await signToken({ t: "a", kid: "key1", exp: Math.floor(now / 1000) + 3600 }, secret);
    return handleRequest(new Request(`https://live.test${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }), env, now);
}

/// ICE 571 Teststadt Nord 12:00 (platform 7) → Teststadt Mitte 13:00, via Testau 12:30.
const journey = () => ({
    legs: [{
        line: "ICE 571", category: "ICE", number: "571", product: "highSpeed", night: false, cancelled: false,
        origin: "Teststadt Nord", originEva: "1000001", destination: "Teststadt Mitte", destinationEva: "1000002",
        departure: { planned: m(0) }, arrival: { planned: m(60) }, departurePlatform: { planned: "7" },
        stops: [{ eva: "1000003", arrival: { planned: m(30) } }, { eva: "1000002", arrival: { planned: m(60) } }],
    }],
});

const plan = (eva, hour, stops) => [`${IRIS}plan/${eva}/261017/${hour}`, `<?xml version="1.0"?><timetable station="x">${stops}</timetable>`];
const PLANS = Object.fromEntries([
    plan("1000001", "12", `<s id="nord-1"><tl c="ICE" n="571"/><dp pt="2610171200" pp="7" l="ICE"/></s><s id="other"><tl c="RE" n="571"/><dp pt="2610171400" pp="1"/></s>`),
    plan("1000003", "12", `<s id="testau-1"><tl c="ICE" n="0571"/><ar pt="2610171230" pp="2"/><dp pt="2610171231" pp="2"/></s>`),
    plan("1000002", "13", `<s id="mitte-1"><tl c="ICE" n="571"/><ar pt="2610171300" pp="3"/></s>`),
]);

// MARK: - State

test("works out the same Live Activity state as the app for every fixture case", () => {
    for (const scenario of fixture.scenarios) {
        for (const { now, state } of scenario.cases) {
            assert.deepEqual(encodeState(contentState(scenario.journey, now)), state, `${scenario.name} at ${now}`);
        }
    }
});

test("pushes dates as seconds since 2001, as ActivityKit decodes them", () => {
    const state = encodeState(contentState(journey(), m(-10)));
    assert.equal(state.plannedTime, m(0) - REFERENCE_DATE);
    assert.equal(state.followUpStorage[0].progressStart, m(0) - REFERENCE_DATE);
});

test("looks again on the app's schedule: every 2 minutes, around arrivals, every minute while transferring", () => {
    // RE 1 from 0 to 30, RE 2 from 40 to 90 (LiveActivityRefreshScheduleTests, the walk in between isn't sent).
    const leg = (depart, arrive) => ({ departure: { planned: m(depart) }, arrival: { planned: m(arrive) } });
    const legs = { legs: [leg(0, 30), leg(40, 90)] };
    const next = (minutes) => (nextRefresh(legs, m(minutes)) - T0) / 60;
    assert.deepEqual([-10, 10, 50, 28, 29, 30, 88.5, 31, 38, 40, 91].map(next), [-8, 12, 52, 29, 30, 31, 89, 32, 39, 42, 93]);
});

// MARK: - IRIS

test("reads IRIS's German times and picks the hour's schedule in German time", () => {
    assert.equal(parseTime("2610171429"), Date.parse("2026-10-17T12:29:00Z") / 1000);
    assert.equal(parseTime("2601151429"), Date.parse("2026-01-15T13:29:00Z") / 1000);
    assert.equal(parseTime("26101714"), null);
    assert.equal(planPath("8000105", Date.parse("2026-10-17T22:30:00Z") / 1000), "plan/8000105/261018/00");
});

test("finds a train by number and planned time, also under another category", () => {
    const stops = parseStops(`<timetable><s id="a"><tl c="ICE" n="0571"/><ar pt="2610171429" pp="7"/></s>`
        + `<s id="b"><tl c="NX" n="1"/><dp pt="2610171430" pp="3" l="RE1"/></s><s id="c"><tl c="ICE" n="571"/><ar pt="2610171529"/></s></timetable>`);
    assert.equal(matchStop(stops, "ICE", "571", parseTime("2610171429"), "arrival").id, "a");
    assert.equal(matchStop(stops, "RE", "1", parseTime("2610171431"), "departure").id, "b");
    assert.equal(matchStop(stops, "IC", "571", parseTime("2610171431"), "arrival").id, "a");
    assert.equal(matchStop(stops, "ICE", "571", parseTime("2610171500"), "arrival"), null);
    assert.equal(categoryOf("S15"), "S");
    assert.equal(categoryOf("ICE 571"), "ICE");
});

test("reads one stop's change out of a station's whole change list", () => {
    const xml = `<timetable><s id="x" eva="1"><m id="r1" t="d" c="43"/><dp ct="2610171436" cp="4"><m t="q" c="1"/></dp></s>`
        + `<s id="y" eva="1"><ar cs="c"/></s></timetable>`;
    assert.equal(changedStop(xml, "x").departure.actualPlatform, "4");
    assert.equal(changedStop(xml, "x").departure.actual, parseTime("2610171436"));
    assert.equal(changedStop(xml, "y").arrival.cancelled, true);
    assert.equal(changedStop(xml, "r1"), null);
    assert.equal(changedStop(xml, "z"), null);
});

test("asks IRIS about the current train's departure before it leaves, then its next stop, and the next train", () => {
    const sides = (minutes) => liveEvents(journey(), m(minutes)).map(event => `${event.side}@${event.eva}`);
    assert.deepEqual(sides(-10), ["departure@1000001", "arrival@1000002"]);
    assert.deepEqual(sides(10), ["arrival@1000003", "arrival@1000002"]);
    // The last stop is the destination: asked once.
    assert.deepEqual(sides(45), ["arrival@1000002"]);
    assert.deepEqual(sides(62), []);
});

// MARK: - HTTP

test("takes an activity over from the genuine app only", async () => {
    const env = await environment();
    const body = { secret: appSecret, pushToken, sandbox: true, journey: journey() };
    assert.equal((await request("PUT", body, { token: false }, env)).status, 401);
    const response = await request("PUT", body, {}, env);
    assert.equal(response.status, 200);
    const [row] = env.DB.rows();
    assert.equal(row.push_token, pushToken);
    assert.equal(row.sandbox, 1);
    assert.equal(row.next_check, m(-8));
    assert.equal(row.ends, m(65));
    assert.equal(JSON.parse(row.state).isDeparture, true);
    // Someone else's ID: neither replaced nor deleted.
    assert.equal((await request("PUT", { ...body, secret: "ef".repeat(32) }, {}, env)).status, 404);
    assert.equal((await request("DELETE", { secret: "ef".repeat(32) }, {}, env)).status, 404);
    assert.equal((await request("DELETE", { secret: appSecret }, {}, env)).status, 204);
    assert.equal(env.DB.rows().length, 0);
    assert.equal((await request("DELETE", { secret: appSecret }, {}, env)).status, 404);
});

test("refuses what doesn't look like a journey and keeps only the fields it uses", async () => {
    const env = await environment();
    for (const bad of [null, { legs: [] }, { legs: [{ line: "ICE 1" }] }, { legs: new Array(13).fill(journey().legs[0]) }]) {
        assert.equal((await request("PUT", { secret: appSecret, pushToken, journey: bad }, {}, env)).status, 400);
    }
    assert.equal((await request("PUT", { secret: appSecret, pushToken: "x", journey: journey() }, {}, env)).status, 400);
    const input = journey();
    Object.assign(input.legs[0], { originRef: { eva: "1", id: "planted" }, originEva: "../x", extra: "dropped" });
    const clean = sanitizeJourney(input);
    assert.equal(clean.legs[0].originRef, undefined);
    assert.equal(clean.legs[0].originEva, undefined);
    assert.equal(clean.legs[0].extra, undefined);
    assert.deepEqual(clean.legs[0].stops[0], { eva: "1000003", arrival: { planned: m(30) } });
});

// MARK: - Cron

async function handedOver(env, now = m(-10)) {
    assert.equal((await request("PUT", { secret: appSecret, pushToken, sandbox: false, journey: journey() }, { now: now * 1000 }, env)).status, 200);
}

test("pushes DB's new delay and platform, and nothing while nothing changes", async () => {
    const env = await environment();
    await handedOver(env);
    const fetch = fakeUpstream({
        ...PLANS,
        [`${IRIS}fchg/1000001`]: `<timetable><s id="nord-1" eva="1000001"><dp ct="2610171208" cp="9"/></s></timetable>`,
        [`${IRIS}fchg/1000002`]: `<timetable><s id="mitte-1" eva="1000002"><ar ct="2610171307"/></s></timetable>`,
        "https://api.push.apple.com/": "",
    });
    assert.equal(await processDueActivities(env, m(-9) * 1000, { fetch }), 0); // not due yet
    assert.equal(await processDueActivities(env, m(-8) * 1000, { fetch }), 1);

    const [push] = fetch.pushes();
    assert.equal(push.url, `https://api.push.apple.com/3/device/${pushToken}`);
    assert.equal(push.init.headers["apns-push-type"], "liveactivity");
    assert.equal(push.init.headers["apns-topic"], "de.goldkunibert.BetterBahn.push-type.liveactivity");
    assert.equal(push.init.headers["apns-priority"], "10");
    assert.match(push.init.headers.authorization, /^bearer /);
    const { aps } = push.body;
    assert.equal(aps.event, "update");
    assert.equal(aps.timestamp, m(-8));
    assert.equal(aps["stale-date"], m(8));
    assert.equal(aps["content-state"].expectedTime, m(8) - REFERENCE_DATE);
    assert.equal(aps["content-state"].platform, "9");
    assert.equal(aps["content-state"].replacedPlatform, "7");
    assert.equal(aps["content-state"].currentDelayMinutes, 8);
    assert.equal(aps["content-state"].followUpStorage[0].expectedTime, m(67) - REFERENCE_DATE);

    const [row] = env.DB.rows();
    assert.equal(row.next_check, m(-6));
    const stored = JSON.parse(row.journey).legs[0];
    assert.deepEqual(stored.originRef, { eva: "1000001", id: "nord-1", platform: "7" });
    assert.deepEqual(stored.departurePlatform, { planned: "7", actual: "9" });
    assert.equal(stored.stops[1].arrival.actual, m(67));

    // Nothing new: IRIS isn't asked for the schedule again, and nothing is pushed.
    const unchanged = fakeUpstream({
        [`${IRIS}fchg/1000001`]: `<timetable><s id="nord-1" eva="1000001"><dp ct="2610171208" cp="9"/></s></timetable>`,
        [`${IRIS}fchg/1000002`]: `<timetable><s id="mitte-1" eva="1000002"><ar ct="2610171307"/></s></timetable>`,
        "https://api.push.apple.com/": "",
    });
    assert.equal(await processDueActivities(env, m(-6) * 1000, { fetch: unchanged }), 1);
    assert.deepEqual(unchanged.calls.map(call => call.url), [`${IRIS}fchg/1000001`, `${IRIS}fchg/1000002`]);
});

test("moving on as the activity already shows it is pushed without urgency", async () => {
    const env = await environment();
    await handedOver(env);
    const fetch = fakeUpstream({
        ...PLANS,
        ...Object.fromEntries([plan("1000002", "13", `<s id="mitte-1"><tl c="ICE" n="571"/><ar pt="2610171300"/></s>`)]),
        [`${IRIS}fchg/`]: "<timetable/>",
        "https://api.push.apple.com/": "",
    });
    // 12:01: the train has left on time, the activity showed its follow-up (riding) by itself since 12:00.
    env.DB.db.prepare("UPDATE activities SET next_check = ?").run(m(1));
    await processDueActivities(env, m(1) * 1000, { fetch });
    const [push] = fetch.pushes();
    assert.equal(push.init.headers["apns-priority"], "5");
    assert.equal(push.body.aps["content-state"].isDeparture, false);
});

test("ends the activity after the arrival and forgets the journey", async () => {
    const env = await environment();
    await handedOver(env);
    const fetch = fakeUpstream({ ...PLANS, [`${IRIS}fchg/`]: "<timetable/>", "https://api.push.apple.com/": "" });
    env.DB.db.prepare("UPDATE activities SET next_check = ?").run(m(61));
    await processDueActivities(env, m(61) * 1000, { fetch });
    const [push] = fetch.pushes();
    assert.equal(push.body.aps.event, "end");
    assert.equal(push.body.aps["content-state"].arrivedFlag, true);
    assert.equal(push.body.aps["dismissal-date"], m(65));
    assert.equal(env.DB.rows().length, 0);
});

test("keeps what the app sent when IRIS is down, and forgets an activity whose token is gone", async () => {
    const env = await environment();
    await handedOver(env);
    const down = fakeUpstream({ [IRIS]: [503, "down"], "https://api.push.apple.com/": [410, JSON.stringify({ reason: "ExpiredToken" })] });
    await processDueActivities(env, m(-8) * 1000, { fetch: down });
    // Nothing changed, so nothing to push; IRIS is asked again next time.
    assert.equal(down.pushes().length, 0);
    const [row] = env.DB.rows();
    assert.equal(JSON.parse(row.journey).legs[0].originRef, undefined);
    assert.equal(row.next_check, m(-6));

    env.DB.db.prepare("UPDATE activities SET next_check = ?").run(m(1));
    await processDueActivities(env, m(1) * 1000, { fetch: down });
    assert.equal(down.pushes().length, 1);
    assert.equal(env.DB.rows().length, 0);
});

test("a train IRIS doesn't know keeps the app's times and isn't looked up again", async () => {
    const env = await environment();
    await handedOver(env);
    const fetch = fakeUpstream({ [`${IRIS}plan/`]: "<timetable/>", [`${IRIS}fchg/`]: "<timetable/>", "https://api.push.apple.com/": "" });
    await processDueActivities(env, m(-8) * 1000, { fetch });
    const leg = JSON.parse(env.DB.rows()[0].journey).legs[0];
    assert.equal(leg.originRef, false);
    assert.equal(leg.departure.actual, undefined);
    assert.equal(fetch.pushes().length, 0);
});

test("a cancellation DB reports shows with its warning", async () => {
    const env = await environment();
    await handedOver(env);
    const fetch = fakeUpstream({
        ...PLANS,
        [`${IRIS}fchg/1000001`]: `<timetable><s id="nord-1" eva="1000001"><dp cs="c"/></s></timetable>`,
        [`${IRIS}fchg/1000002`]: "<timetable/>",
        "https://api.push.apple.com/": "",
    });
    await processDueActivities(env, m(-8) * 1000, { fetch });
    const state = fetch.pushes()[0].body.aps["content-state"];
    assert.equal(state.cancelled, true);
    assert.equal(state.warning, "ICE 571 fällt aus");
});

test("forgets a journey long after its arrival without asking anyone", async () => {
    const env = await environment();
    await handedOver(env);
    const fetch = fakeUpstream({});
    env.DB.db.prepare("UPDATE activities SET next_check = 0").run();
    await processDueActivities(env, m(200) * 1000, { fetch });
    assert.equal(fetch.calls.length, 0);
    assert.equal(env.DB.rows().length, 0);
});
