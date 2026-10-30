import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { signToken, toBase64 } from "../shared/appattest.mjs";
import { parseTime } from "../shared/iris.mjs";
import { clock, processDueCommutes } from "./commute.mjs";
import { handleRequest } from "./worker.mjs";

/// The German text of an alert, without the keys the app translates it with.
const german = ({ title, body }) => ({ title, body });

const secret = "test-secret";
const schema = readFileSync(new URL("./schema.sql", import.meta.url), "utf8");
const deviceToken = "cd".repeat(32);
const id = "0123456789abcdef0123456789abcdef";
const appSecret = "ab".repeat(32);
/// Monday 19 October 2026, 7:30 in Germany (summer time).
const now = Date.parse("2026-10-19T05:30:00Z");
const at = (hhmm) => Date.parse(`2026-10-19T${String(Number(hhmm.slice(0, 2)) - 2).padStart(2, "0")}:${hhmm.slice(2)}:00Z`);

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
    rows() { return this.db.prepare("SELECT * FROM commutes").all(); }
}

let apnsKey;
async function environment() {
    if (!apnsKey) {
        const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
        const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
        apnsKey = `-----BEGIN PRIVATE KEY-----\n${toBase64(pkcs8)}\n-----END PRIVATE KEY-----`;
    }
    return {
        DB: new FakeD1(), TOKEN_SECRET: secret, INTERVAL_MINUTES: "1",
        APNS_KEY: apnsKey, APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123", APNS_TOPIC: "de.goldkunibert.BetterBahn",
    };
}

/// IRIS and APNs stand-in. `iris` maps a path ("plan/8010093/261019/07", "fchg/8010093") to its XML.
function upstream(iris) {
    const calls = [];
    const pushes = [];
    const fetch = async function (url, init = {}) {
        if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
        calls.push(url);
        if (url.includes("push.apple.com")) {
            pushes.push({ payload: JSON.parse(init.body), collapse: init.headers["apns-collapse-id"] });
            return new Response("", { status: 200 });
        }
        const path = url.replace("https://iris.noncd.db.de/iris-tts/timetable/", "");
        const xml = typeof iris === "function" ? iris(path) : iris[path];
        return xml === undefined ? new Response("", { status: 404 }) : new Response(xml, { status: 200 });
    };
    return { fetch, calls, pushes };
}

const plan = (...stops) => `<?xml version="1.0"?><timetable station="X">${stops.join("")}</timetable>`;
const planned = (stopId, number, { ar, dp, pp = "2" }) =>
    `<s id="${stopId}"><tl f="N" t="p" o="800244" c="RE" n="${number}"/>`
    + (ar ? `<ar pt="${ar}" pp="${pp}" l="3"/>` : "") + (dp ? `<dp pt="${dp}" pp="${pp}" l="3"/>` : "") + "</s>";

const re3 = { line: "RE 3", category: "RE", number: "3354",
    from: { eva: "8010093", name: "Eberswalde Hbf", time: at("0742") / 1000 },
    to: { eva: "8011102", name: "Berlin Gesundbrunnen", time: at("0814") / 1000 } };
const journey = { id: "J1", threshold: 5, legs: [re3] };

const baseIris = {
    "plan/8010093/261019/07": plan(planned("e-1", "3354", { dp: "2610190742" }), planned("e-2", "3356", { dp: "2610190842" })),
    "plan/8011102/261019/08": plan(planned("g-1", "3354", { ar: "2610190814", pp: "7" })),
    "fchg/8010093": plan(),
    "fchg/8011102": plan(),
};

async function attest() {
    return { "X-BetterBahn-Token": await signToken({ t: "a", kid: "key-1", exp: Math.floor(now / 1000) + 3600 }, secret) };
}

async function put(env, body, fetch, path = `/commutes/${id}`) {
    const request = new Request(`https://push.test${path}`, {
        method: "PUT", headers: await attest(),
        body: JSON.stringify({ secret: appSecret, deviceToken, sandbox: false, ...body }),
    });
    return handleRequest(request, env, now, { fetch });
}

test("IRIS times are German time", () => {
    assert.equal(parseTime("2610190742") * 1000, Date.parse("2026-10-19T05:42:00Z"));
    // After summer time ended on the 25th.
    assert.equal(parseTime("2610260742") * 1000, Date.parse("2026-10-26T06:42:00Z"));
    assert.equal(clock(Date.parse("2026-10-26T06:42:00Z")), "7:42");
});

test("signing up finds every train in the schedule", async () => {
    const env = await environment();
    const { fetch } = upstream(baseIris);
    const response = await put(env, { journeys: [journey] }, fetch);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { watched: ["J1"] });
    const [row] = env.DB.rows();
    assert.equal(row.device_token, deviceToken);
    const [stored] = JSON.parse(row.journeys);
    assert.equal(stored.legs[0].departure.id, "e-1");
    assert.equal(stored.legs[0].arrival.id, "g-1");
    assert.equal(stored.legs[0].arrival.platform, "7");
});

test("a train missing from the schedule isn't watched", async () => {
    const env = await environment();
    const { fetch } = upstream({});
    const response = await put(env, { journeys: [journey] }, fetch);
    assert.deepEqual(await response.json(), { watched: [] });
    assert.equal(env.DB.rows().length, 0);
});

test("another secret can't change a device's journeys, an empty list signs off", async () => {
    const env = await environment();
    const { fetch, calls } = upstream(baseIris);
    await put(env, { journeys: [journey] }, fetch);
    const stolen = await put(env, { secret: "ef".repeat(32), journeys: [] }, fetch);
    assert.equal(stolen.status, 404);
    assert.equal(env.DB.rows().length, 1);
    // The same trains again: nothing is looked up a second time.
    const before = calls.length;
    await put(env, { journeys: [journey] }, fetch);
    assert.equal(calls.length, before);
    const off = await put(env, { journeys: [] }, fetch);
    assert.deepEqual(await off.json(), { watched: [] });
    assert.equal(env.DB.rows().length, 0);
});

test("refuses invalid journeys and requests without App Attest", async () => {
    const env = await environment();
    const { fetch } = upstream(baseIris);
    const invalid = await put(env, { journeys: [{ ...journey, legs: [{ ...re3, number: "x" }] }] }, fetch);
    assert.equal(invalid.status, 400);
    const request = new Request(`https://push.test/commutes/${id}`, { method: "PUT", body: "{}" });
    assert.equal((await handleRequest(request, env, now, { fetch })).status, 401);
});

test("reports a delay from the threshold on and again when it grew", async () => {
    const env = await environment();
    let delay = "2610190750";
    const iris = (path) => path === "fchg/8010093"
        ? plan(`<s id="e-1" eva="8010093"><dp ct="${delay}" l="3"/></s>`)
        : baseIris[path];
    const { fetch, pushes } = upstream(iris);
    await put(env, { journeys: [journey] }, fetch);
    await processDueCommutes(env, now, { fetch });
    assert.equal(pushes.length, 1);
    assert.deepEqual(pushes[0].payload.aps.alert, {
        title: "RE 3: +8 Min.", body: "Ab Eberswalde Hbf um 7:50 statt 7:42.",
        "title-loc-key": "%@: +%@ Min.", "title-loc-args": ["RE 3", "8"],
        "loc-key": "Ab %@ um %@ statt %@.", "loc-args": ["Eberswalde Hbf", "7:50", "7:42"],
    });
    assert.equal(pushes[0].payload.commuteJourneyID, "J1");
    assert.equal(pushes[0].collapse, "commute-J1-delay-0");
    await processDueCommutes(env, now + 60000, { fetch });
    assert.equal(pushes.length, 1);
    delay = "2610190755";
    await processDueCommutes(env, now + 120000, { fetch });
    assert.equal(pushes.length, 2);
    assert.equal(pushes[1].payload.aps.alert.title, "RE 3: +13 Min.");
});

test("stays quiet below the threshold", async () => {
    const env = await environment();
    const iris = { ...baseIris, "fchg/8010093": plan(`<s id="e-1" eva="8010093"><dp ct="2610190745"/></s>`) };
    const { fetch, pushes } = upstream(iris);
    await put(env, { journeys: [journey] }, fetch);
    await processDueCommutes(env, now, { fetch });
    assert.equal(pushes.length, 0);
});

test("reports a cancellation once", async () => {
    const env = await environment();
    const iris = { ...baseIris, "fchg/8010093": plan(`<s id="e-1" eva="8010093"><dp cs="c" clt="2610190700"/></s>`) };
    const { fetch, pushes } = upstream(iris);
    await put(env, { journeys: [journey] }, fetch);
    await processDueCommutes(env, now, { fetch });
    await processDueCommutes(env, now + 60000, { fetch });
    assert.equal(pushes.length, 1);
    assert.deepEqual(german(pushes[0].payload.aps.alert), { title: "RE 3 fällt aus", body: "Die Fahrt von Eberswalde Hbf nach Berlin Gesundbrunnen findet nicht statt." });
});

test("reports a platform change, not a sector", async () => {
    const env = await environment();
    let platform = "2 A-C";
    const iris = (path) => path === "fchg/8010093" ? plan(`<s id="e-1" eva="8010093"><dp cp="${platform}"/></s>`) : baseIris[path];
    const { fetch, pushes } = upstream(iris);
    await put(env, { journeys: [journey] }, fetch);
    await processDueCommutes(env, now, { fetch });
    assert.equal(pushes.length, 0);
    platform = "4";
    await processDueCommutes(env, now + 60000, { fetch });
    assert.deepEqual(german(pushes[0].payload.aps.alert), { title: "RE 3: Gleiswechsel", body: "Abfahrt Eberswalde Hbf jetzt von Gleis 4 (statt 2)" });
    await processDueCommutes(env, now + 120000, { fetch });
    assert.equal(pushes.length, 1);
});

test("warns when a transfer gets tight", async () => {
    const env = await environment();
    const s1 = { ...re3, to: { eva: "8011102", name: "Berlin Gesundbrunnen", time: at("0814") / 1000 } };
    const s2 = { line: "S 1", category: "S", number: "1234",
        from: { eva: "8011102", name: "Berlin Gesundbrunnen", time: at("0822") / 1000 },
        to: { eva: "8011306", name: "Berlin Friedrichstraße", time: at("0835") / 1000 } };
    const iris = {
        ...baseIris,
        "plan/8011102/261019/08": plan(planned("g-1", "3354", { ar: "2610190814", pp: "7" }),
            `<s id="g-2"><tl c="S" n="1234"/><dp pt="2610190822" pp="1"/></s>`),
        "plan/8011306/261019/08": plan(`<s id="f-2"><tl c="S" n="1234"/><ar pt="2610190835" pp="3"/></s>`),
        "fchg/8011102": plan(`<s id="g-1" eva="8011102"><ar ct="2610190819"/></s>`),
        "fchg/8011306": plan(),
    };
    const { fetch, pushes } = upstream(iris);
    const response = await put(env, { journeys: [{ id: "J2", threshold: 10, legs: [s1, s2] }] }, fetch);
    assert.deepEqual(await response.json(), { watched: ["J2"] });
    await processDueCommutes(env, now, { fetch });
    assert.equal(pushes.length, 1);
    assert.deepEqual(german(pushes[0].payload.aps.alert), {
        title: "Umstieg in Berlin Gesundbrunnen wird knapp", body: "3 Min. zum Umsteigen von RE 3 in S 1.",
    });
    assert.equal(pushes[0].payload.aps.alert["loc-key"], "%@ Min. zum Umsteigen von %@ in %@.");
});

test("forgets journeys that have arrived", async () => {
    const env = await environment();
    const { fetch } = upstream(baseIris);
    await put(env, { journeys: [journey] }, fetch);
    await processDueCommutes(env, at("0850"), { fetch });
    assert.equal(env.DB.rows().length, 0);
});
