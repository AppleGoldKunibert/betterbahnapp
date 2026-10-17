import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { signToken } from "../shared/appattest.mjs";
import { handleRequest, trainStatistics } from "./worker.mjs";

const secret = "test-secret";
const schema = readFileSync(new URL("./schema.sql", import.meta.url), "utf8");

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
            async run() { db.prepare(sql).run(...this.values); return { success: true }; },
        };
        return statement;
    }
}

// Asked at noon.
const askedAt = Date.parse("2026-10-06T10:00:00Z");
const FULDA = "8000115";

async function token() {
    return signToken({ t: "a", kid: "key-1", exp: Math.floor(askedAt / 1000) + 3600 }, secret);
}

async function askStats(env, trains) {
    return handleRequest(new Request("https://betterbahn-stats.example/train-stats", {
        method: "POST", headers: { "Content-Type": "application/json", "X-BetterBahn-Token": await token() }, body: JSON.stringify({ trains }),
    }), env, askedAt);
}

/// A run of `number` on `day`; `stop` is its row at Fulda without the EVA number (see schema.sql for the format).
function addRun(db, day, stop, { cancelled = 0, category = "ICE", number = "1095", stops } = {}) {
    const run = { c: category, x: cancelled, s: stops ?? [["8000261", null, 1, "19", null, 0], [FULDA, ...stop], ["8000105", 4, null, "8", null, 0]] };
    const existing = db.db.prepare("SELECT runs FROM train_days WHERE number = ? AND day = ?").get(number, day);
    const runs = existing ? [...JSON.parse(existing.runs), run] : [run];
    db.db.prepare("INSERT OR REPLACE INTO train_days (number, day, runs) VALUES (?, ?, ?)").run(number, day, JSON.stringify(runs));
}

test("answers a train's delays, cancellations and platform moves per stop", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    // [arrivalDelay, departureDelay, platform, changedPlatform, flags]
    addRun(env.DB, "2026-10-01", [0, 1, "7", null, 0]);
    addRun(env.DB, "2026-10-02", [12, 12, "7", "8", 0]);
    addRun(env.DB, "2026-10-03", [3, 3, "7", null, 0]);
    addRun(env.DB, "2026-10-04", [null, null, "7", null, 1]);
    addRun(env.DB, "2026-10-05", [null, null, "7", null, 1], { cancelled: 1 });
    // Too old and another train don't count.
    addRun(env.DB, "2026-08-01", [50, 50, "7", null, 0]);
    addRun(env.DB, "2026-10-01", [99, 99, "7", null, 0], { number: "1096" });

    const response = await askStats(env, [{ category: "ice", number: "1095", evas: [FULDA, "8000105", "9999999"] }]);
    assert.equal(response.status, 200);
    const [train] = (await response.json()).trains;
    assert.equal(train.category, "ICE");
    assert.equal(train.days, 30);
    assert.equal(train.runs, 5);
    assert.equal(train.cancelled, 1);
    assert.equal(train.formationRuns, undefined, "no Wagenreihung any more (#336)");

    const fulda = train.stops[FULDA];
    assert.equal(fulda.runs, 5);
    assert.equal(fulda.cancelled, 2);
    assert.deepEqual(fulda.arrival.sort((a, b) => a - b), [0, 3, 12]);
    assert.deepEqual(fulda.departure.sort((a, b) => a - b), [1, 3, 12]);
    assert.deepEqual(fulda.platforms, [{ from: "7", to: "7", n: 2 }, { from: "7", to: "8", n: 1 }]);
    assert.deepEqual(train.stops["8000105"].arrival, [4, 4, 4, 4]);
    assert.equal(train.stops["9999999"], undefined, "a stop the train never had is left out");
});

test("finds a stop asked for by its lower level under the main station", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    addRun(env.DB, "2026-10-01", [0, 1, "7", null, 0], { stops: [["8011160", 5, null, "7", null, 0]] });
    const [train] = (await (await askStats(env, [{ category: "ICE", number: "1095", evas: ["8098160"] }])).json()).trains;
    assert.deepEqual(train.stops["8098160"].arrival, [5]);
});

test("refuses train statistics without a token, with malformed trains or too many", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    const ask = (trains, headers) => handleRequest(new Request("https://betterbahn-stats.example/train-stats", {
        method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify({ trains }),
    }), env, askedAt);
    assert.equal((await ask([])).status, 401);
    assert.equal((await askStats(env, [{ category: "ICE", number: "1095", evas: [] }])).status, 200);
    assert.equal((await askStats(env, Array(9).fill({ category: "ICE", number: "1095", evas: [] }))).status, 400);
    assert.equal((await askStats(env, [{ category: "ICE; DROP", number: "1095", evas: [] }])).status, 400);
    assert.equal((await askStats(env, [{ category: "ICE", number: "1095", evas: ["x"] }])).status, 400);
    assert.equal((await askStats(env, [{ category: "ICE", number: "1095", evas: Array(13).fill("8000115") }])).status, 400);
    const get = await handleRequest(new Request("https://betterbahn-stats.example/train-stats"), env, askedAt);
    assert.equal(get.status, 405);
});

test("the old sightings endpoint is gone", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    const response = await handleRequest(new Request("https://betterbahn-stats.example/sightings", { method: "POST", body: "{}" }), env, askedAt);
    assert.equal(response.status, 404);
});

test("rate limits train statistics per app install", async () => {
    const keys = [];
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret, STATS_LIMITER: { limit: async ({ key }) => { keys.push(key); return { success: false }; } } };
    assert.equal((await askStats(env, [])).status, 429);
    assert.deepEqual(keys, ["key-1"]);
});

test("finds a regional train under its operator's category, by run number and stop", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    // Stored as "HLB 3185" and "RE 3185"; the app knows it as "RE" with the run number 3185.
    addRun(env.DB, "2026-10-01", [4, 4, "7", null, 0], { category: "HLB", number: "3185" });
    addRun(env.DB, "2026-10-02", [6, 6, "7", "8", 0], { category: "RE", number: "3185" });
    // Another regional train with that number that doesn't stop at Fulda, and a long-distance one that does.
    addRun(env.DB, "2026-10-03", [], { category: "RB", number: "3185", stops: [["8000999", 9, 9, "1", null, 0]] });
    addRun(env.DB, "2026-10-04", [30, 30, "7", null, 0], { category: "ICE", number: "3185" });

    const [train] = (await (await askStats(env, [{ category: "RE", number: "3185", evas: [FULDA] }])).json()).trains;
    assert.equal(train.runs, 2);
    assert.deepEqual(train.stops[FULDA].arrival.sort(), [4, 6]);

    // An ICE is only found as an ICE.
    const [ice] = (await (await askStats(env, [{ category: "ICE", number: "3185", evas: [FULDA] }])).json()).trains;
    assert.deepEqual(ice.stops[FULDA].arrival, [30]);
});

test("skips malformed runs instead of failing", () => {
    const answer = trainStatistics([null, { c: "ICE" }, { c: "ICE", x: 0, s: [[FULDA, 2, 2, "1", null, 0]] }], { category: "ICE", number: "1", evas: [FULDA] });
    assert.equal(answer.runs, 2);
    assert.deepEqual(answer.stops[FULDA].arrival, [2]);
});
