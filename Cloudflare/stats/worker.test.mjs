import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { signToken } from "../shared/appattest.mjs";
import { berlinToUnix, handleRequest, journeyFields, parseJourney, processDueRuns, runKey, trainStatistics } from "./worker.mjs";

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
    async batch(statements) { return Promise.all(statements.map(statement => statement.run())); }
    rows() { return this.db.prepare("SELECT * FROM runs ORDER BY key").all(); }
}

const ICE_ID = "2|#VN#1#ST#1759740932#PI#0#ZI#185046#TA#0#DA#61026#1S#8000261#1T#1756#LS#8000105#LT#2209#PU#80#RT#1#CA#ICE#ZE#1095#ZB#ICE  1095#PC#0#FR#8000261#FT#1756#TO#8000105#TT#2209#";
const S_ID = "2|#VN#1#ST#1759740932#PI#0#ZI#1#TA#0#DA#61026#1S#8002549#1T#1800#LS#8002553#LT#1840#PU#80#RT#1#CA#S#ZE#5540#ZB#S 5#PC#4#";

function journey({ arrivalRt = "2026-10-06T22:14:00", platformRt = "8", canceled = false } = {}) {
    return {
        zugName: "ICE 1095",
        himMeldungen: [{ ueberschrift: "Bauarbeiten", text: "Bauarbeiten zwischen Nürnberg und Würzburg." }],
        halte: [
            { id: "A=1@O=München Hbf@L=8000261@", extId: "8000261", name: "München Hbf", gleis: "19",
                abfahrtsZeitpunkt: "2026-10-06T17:56:00", ezAbfahrtsZeitpunkt: "2026-10-06T17:58:00" },
            { extId: "8000284", name: "Nürnberg Hbf", gleis: "7", ezGleis: platformRt, canceled,
                ankunftsZeitpunkt: "2026-10-06T19:00:00", ezAnkunftsZeitpunkt: "2026-10-06T19:05:00",
                abfahrtsZeitpunkt: "2026-10-06T19:02:00", ezAbfahrtsZeitpunkt: "2026-10-06T19:07:00",
                priorisierteMeldungen: [{ type: "INFO", text: "Reparatur am Zug" }] },
            { extId: "8000105", name: "Frankfurt(Main)Hbf", gleis: "8",
                ankunftsZeitpunkt: "2026-10-06T22:09:00", ezAnkunftsZeitpunkt: arrivalRt },
        ],
    };
}

const sequence = {
    sequenceStatus: "MATCHES_SCHEDULE",
    groups: [{ name: "ICE9026", transport: { category: "ICE", number: 1095, destination: { name: "Frankfurt(Main)Hbf" } },
        vehicles: [{ vehicleID: "938054110013", type: { constructionType: "I4011" } }] }],
};

/// bahn.de stand-in: answers by path and records each request.
function fakeBahnDe(routes) {
    const calls = [];
    const fetch = async url => {
        calls.push(url);
        const path = new URL(url).pathname;
        const answer = Object.entries(routes).find(([prefix]) => path.endsWith(prefix))?.[1];
        if (!answer) return new Response("", { status: 404 });
        const { status = 200, body } = typeof answer === "function" ? answer() : answer;
        return new Response(JSON.stringify(body), { status });
    };
    return { fetch, calls };
}

// Seen at noon on the train's day.
const seenAt = Date.parse("2026-10-06T10:00:00Z");

async function report(env, ids, headers = {}) {
    return handleRequest(new Request("https://betterbahn-stats.example/sightings", {
        method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify({ journeyIds: ids }),
    }), env, seenAt);
}

async function token() {
    return signToken({ t: "a", kid: "key-1", exp: Math.floor(seenAt / 1000) + 3600 }, secret);
}

test("reads the fields of a bahn.de journey ID and keys a run by day, train and first stop", () => {
    assert.equal(journeyFields(ICE_ID).ZE, "1095");
    assert.equal(journeyFields(ICE_ID).CA, "ICE");
    assert.equal(runKey(ICE_ID), "61026|ICE|1095|8000261");
    assert.equal(runKey("2|#VN#1#ST#1#"), "2|#VN#1#ST#1#");
});

test("stores each seen train once and leaves out S-Bahn and malformed IDs", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    const headers = { "X-BetterBahn-Token": await token() };
    const response = await report(env, [ICE_ID, ICE_ID.replace("#ST#1759740932", "#ST#1759740999"), S_ID, "<script>", 42], headers);
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { accepted: 1 });
    await report(env, [ICE_ID], headers);
    const rows = env.DB.rows();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].state, "new");
});

test("refuses sightings without an App Attest token and too many at once", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    assert.equal((await report(env, [ICE_ID])).status, 401);
    assert.equal((await report(env, [ICE_ID], { "X-BetterBahn-Token": "forged" })).status, 401);
    assert.equal((await report(env, Array(101).fill(ICE_ID), { "X-BetterBahn-Token": await token() })).status, 400);
    assert.equal((await report({ ...env, ALLOW_UNATTESTED: "true" }, [ICE_ID])).status, 202);
});

test("follows a run from its schedule over its Wagenreihung to its final state", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret, ALLOW_UNATTESTED: "true" };
    await report(env, [ICE_ID]);
    const bahnDe = fakeBahnDe({ "reiseloesung/fahrt": { body: journey() }, "vehicle-sequence": { body: sequence } });

    // Seen in the afternoon: the schedule is stored, the Wagenreihung is due 10 minutes before departure.
    const afternoon = Date.parse("2026-10-06T13:00:00Z");
    assert.equal(await processDueRuns(env, afternoon, bahnDe), 1);
    let [run] = env.DB.rows();
    assert.equal(run.state, "planned");
    assert.equal(run.name, "ICE 1095");
    assert.equal(run.category, "ICE");
    assert.equal(run.number, "1095");
    assert.equal(run.service_day, "2026-10-06");
    assert.equal(run.origin_eva, "8000261");
    assert.equal(run.destination_eva, "8000105");
    assert.equal(run.next_check, berlinToUnix("2026-10-06T17:46"));
    assert.equal(await processDueRuns(env, afternoon, bahnDe), 0, "nothing due before then");

    // At departure: the Wagenreihung.
    assert.equal(await processDueRuns(env, berlinToUnix("2026-10-06T17:46") * 1000, bahnDe), 1);
    [run] = env.DB.rows();
    assert.equal(run.state, "formed");
    assert.deepEqual(JSON.parse(run.formation), {
        status: "MATCHES_SCHEDULE",
        groups: [{ name: "ICE9026", category: "ICE", number: 1095, destination: "Frankfurt(Main)Hbf", vehicles: [{ type: "I4011", id: "938054110013" }] }],
    });
    const query = new URL(bahnDe.calls.at(-1)).searchParams;
    assert.equal(query.get("evaNumber"), "8000261");
    assert.equal(query.get("date"), "2026-10-06");
    assert.equal(query.get("time"), "2026-10-06T15:56:00.000Z");
    assert.equal(run.next_check, berlinToUnix("2026-10-06T22:39"));

    // Half an hour after arrival: the final state.
    assert.equal(await processDueRuns(env, berlinToUnix("2026-10-06T22:45") * 1000, bahnDe), 1);
    [run] = env.DB.rows();
    assert.equal(run.state, "done");
    assert.equal(run.final_delay, 5);
    assert.equal(run.cancelled, 0);
    assert.deepEqual(JSON.parse(run.messages), ["Bauarbeiten zwischen Nürnberg und Würzburg."]);
    assert.deepEqual(JSON.parse(run.stops), [
        ["8000261", null, null, 0, 2, "19", null, 0],
        ["8000284", 64, 5, 66, 5, "7", "8", 0, ["Reparatur am Zug"]],
        ["8000105", 253, 5, null, null, "8", null, 0],
    ]);
    const stations = env.DB.db.prepare("SELECT * FROM stations ORDER BY eva").all();
    assert.deepEqual(stations.map(s => s.name), ["Frankfurt(Main)Hbf", "München Hbf", "Nürnberg Hbf"]);
    // The stats query from schema.sql works on the stored format.
    const delays = env.DB.db.prepare("SELECT s.value->>0 AS eva, avg(s.value->>2) AS delay FROM runs, json_each(runs.stops) s WHERE state = 'done' GROUP BY eva ORDER BY eva").all();
    assert.deepEqual(delays.map(d => [d.eva, d.delay]), [["8000105", 5], ["8000261", null], ["8000284", 5]]);
});

test("looks again at a train still running late, then stores it", async () => {
    const env = { DB: new FakeD1(), ALLOW_UNATTESTED: "true" };
    await report(env, [ICE_ID]);
    const late = fakeBahnDe({ "reiseloesung/fahrt": { body: journey({ arrivalRt: "2026-10-06T23:30:00" }) } });
    // Seen after departure: no Wagenreihung any more.
    await processDueRuns(env, berlinToUnix("2026-10-06T18:30") * 1000, late);
    assert.equal(env.DB.rows()[0].state, "formed");

    await processDueRuns(env, berlinToUnix("2026-10-06T22:40") * 1000, late);
    let [run] = env.DB.rows();
    assert.equal(run.state, "formed");
    assert.equal(run.next_check, berlinToUnix("2026-10-07T00:00"));

    await processDueRuns(env, berlinToUnix("2026-10-07T00:05") * 1000, late);
    [run] = env.DB.rows();
    assert.equal(run.state, "done");
    assert.equal(run.final_delay, 81);
});

test("drops trains without realtime, without a stop in Germany, or unknown to bahn.de", async () => {
    const noRealtime = journey({ arrivalRt: null, platformRt: null });
    for (const halt of noRealtime.halte) { delete halt.ezAbfahrtsZeitpunkt; delete halt.ezAnkunftsZeitpunkt; }
    const abroad = journey();
    abroad.halte.forEach((halt, index) => { halt.extId = `810000${index}`; });

    for (const [body, status] of [[noRealtime, 200], [abroad, 200], [{}, 404]]) {
        const env = { DB: new FakeD1(), ALLOW_UNATTESTED: "true" };
        await report(env, [ICE_ID]);
        const bahnDe = fakeBahnDe({ "reiseloesung/fahrt": { status, body } });
        await processDueRuns(env, berlinToUnix("2026-10-06T18:30") * 1000, bahnDe);
        await processDueRuns(env, berlinToUnix("2026-10-06T23:00") * 1000, bahnDe);
        assert.equal(env.DB.rows().length, 0);
    }
});

test("goes on without a Wagenreihung when bahn.de refuses it", async () => {
    const env = { DB: new FakeD1(), ALLOW_UNATTESTED: "true" };
    await report(env, [ICE_ID]);
    const bahnDe = fakeBahnDe({ "reiseloesung/fahrt": { body: journey() }, "vehicle-sequence": { status: 429, body: {} } });
    await processDueRuns(env, Date.parse("2026-10-06T13:00:00Z"), bahnDe);
    await processDueRuns(env, berlinToUnix("2026-10-06T17:46") * 1000, bahnDe);
    const [run] = env.DB.rows();
    assert.equal(run.state, "formed");
    assert.equal(run.formation, null);
});

test("retries when bahn.de fails and gives up after five attempts", async () => {
    const env = { DB: new FakeD1(), ALLOW_UNATTESTED: "true" };
    await report(env, [ICE_ID]);
    const blocked = fakeBahnDe({ "reiseloesung/fahrt": { status: 403, body: {} } });
    let now = Date.parse("2026-10-06T13:00:00Z");
    for (let attempt = 1; attempt < 5; attempt++) {
        await processDueRuns(env, now, blocked);
        assert.equal(env.DB.rows()[0].attempts, attempt);
        now += 10 * 60 * 1000;
    }
    await processDueRuns(env, now, blocked);
    assert.equal(env.DB.rows().length, 0);
});

test("a cancelled train is kept with its cancellation", () => {
    const cancelled = journey({ canceled: true });
    const parsed = parseJourney(cancelled, ICE_ID);
    assert.equal(parsed.stops[1].cancelled, true);
    assert.equal(parsed.hasRealtime, true);
});

test("Berlin local times convert across daylight saving time", () => {
    assert.equal(berlinToUnix("2026-10-06T18:30"), Date.parse("2026-10-06T16:30:00Z") / 1000);
    assert.equal(berlinToUnix("2026-12-06T18:30"), Date.parse("2026-12-06T17:30:00Z") / 1000);
});

// MARK: - Train statistics (#316)

const FULDA = "8000115";
const ICE4 = { name: "ICE9465", category: "ICE", number: 1095, destination: "Berlin Hbf",
    vehicles: [{ type: "I0812", id: "938058120011" }, { type: "I1412", id: "938054120029" }] };
const ICE1 = { name: "ICE0160", category: "ICE", number: 1095, destination: "Berlin Hbf",
    vehicles: [{ type: "I4010", id: "938054010021" }, { type: "I8010", id: "938058010034" }] };

/// A finished run of ICE 1095 on `day`; `stop` is its row at Fulda (see schema.sql for the format).
function addRun(db, day, stop, { cancelled = 0, formation = null, status = "MATCHES_SCHEDULE", category = "ICE", number = "1095" } = {}) {
    db.db.prepare("INSERT INTO runs (key, journey_id, state, next_check, first_seen, service_day, category, number, cancelled, formation, stops) " +
        "VALUES (?, 'x', 'done', 0, 0, ?, ?, ?, ?, ?, ?)")
        .run(`${day}|${category}|${number}`, day, category, number, cancelled, formation ? JSON.stringify({ status, groups: [formation] }) : null,
            JSON.stringify([["8000261", null, null, 0, 1, "19", null, 0], [FULDA, ...stop], ["8000105", 253, 4, null, null, "8", null, 0]]));
}

async function askStats(env, trains) {
    return handleRequest(new Request("https://betterbahn-stats.example/train-stats", {
        method: "POST", headers: { "Content-Type": "application/json", "X-BetterBahn-Token": await token() }, body: JSON.stringify({ trains }),
    }), env, seenAt);
}

test("answers a train's delays, cancellations, platform moves and vehicles per stop", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    // [arrival, arrivalDelay, departure, departureDelay, platform, changedPlatform, flags]
    addRun(env.DB, "2026-10-01", [120, 0, 122, 1, "7", null, 0], { formation: ICE4 });
    addRun(env.DB, "2026-10-02", [120, 12, 122, 12, "7", "8", 0], { formation: ICE4 });
    // ICE 1 instead of the planned vehicle on one day; planned ICE 1 on another doesn't count.
    addRun(env.DB, "2026-10-03", [120, 3, 122, 3, "7", null, 0], { formation: ICE1, status: "DIFFERS_FROM_SCHEDULE" });
    addRun(env.DB, "2026-10-04", [120, null, 122, null, "7", null, 1], { formation: ICE1 });
    addRun(env.DB, "2026-10-05", [120, null, 122, null, "7", null, 1], { cancelled: 1 });
    // Too old, another train and another day's other number don't count.
    addRun(env.DB, "2026-08-01", [120, 50, 122, 50, "7", null, 0]);
    addRun(env.DB, "2026-10-01", [120, 99, 122, 99, "7", null, 0], { number: "1096" });

    const response = await askStats(env, [{ category: "ice", number: "1095", evas: [FULDA, "8000105", "9999999"] }]);
    assert.equal(response.status, 200);
    const [train] = (await response.json()).trains;
    assert.equal(train.category, "ICE");
    assert.equal(train.days, 30);
    assert.equal(train.runs, 5);
    assert.equal(train.cancelled, 1);

    const fulda = train.stops[FULDA];
    assert.equal(fulda.runs, 5);
    assert.equal(fulda.cancelled, 2);
    assert.deepEqual(fulda.arrival.sort((a, b) => a - b), [0, 3, 12]);
    assert.deepEqual(fulda.departure.sort((a, b) => a - b), [1, 3, 12]);
    assert.deepEqual(fulda.platforms, [{ from: "7", to: "7", n: 2 }, { from: "7", to: "8", n: 1 }]);
    assert.deepEqual(train.stops["8000105"].arrival, [4, 4, 4, 4]);
    assert.equal(train.stops["9999999"], undefined, "a stop the train never had is left out");

    assert.equal(train.formationRuns, 4);
    assert.equal(train.unplannedRuns, 1);
    assert.deepEqual(train.unplannedFormations.map(f => f.n), [1]);
    // In bahn.de's Wagenreihung shape, so the app names the series with its own rules.
    assert.deepEqual(train.unplannedFormations[0].groups[0], {
        name: "ICE0160", transport: { category: "ICE", number: 1095 },
        vehicles: [{ vehicleID: "938054010021", type: { constructionType: "I4010" } }, { vehicleID: "938058010034", type: { constructionType: "I8010" } }],
    });
});

test("counts only vehicles bahn.de marks as differing from the day's schedule, one kind per series, and a coupled train's own half", () => {
    const otherHalf = { ...ICE4, name: "ICE9999", number: 940 };
    const run = (group, status = "DIFFERS_FROM_SCHEDULE") => ({ cancelled: 0, formation: JSON.stringify({ status, groups: group }), stops: "[]" });
    const answer = trainStatistics([
        run([{ ...ICE4, name: "ICE9465" }]), run([{ ...ICE4, name: "ICE9470" }]), run([otherHalf, ICE1]),
        run([ICE1], "MATCHES_SCHEDULE"), run([ICE1], "UNKNOWN"), run(null),
    ], { category: "ICE", number: "1095", evas: [] });
    // Four runs have a known status; the unknown one and the one without vehicles are left out.
    assert.equal(answer.formationRuns, 4);
    assert.equal(answer.unplannedRuns, 3);
    assert.deepEqual(answer.unplannedFormations.map(f => [f.n, f.groups.length, f.groups[0].name]), [[2, 1, "ICE9465"], [1, 1, "ICE0160"]]);
});

test("refuses train statistics without a token, with malformed trains or too many", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    const ask = (trains, headers) => handleRequest(new Request("https://betterbahn-stats.example/train-stats", {
        method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify({ trains }),
    }), env, seenAt);
    assert.equal((await ask([])).status, 401);
    assert.equal((await askStats(env, [{ category: "ICE", number: "1095", evas: [] }])).status, 200);
    assert.equal((await askStats(env, Array(9).fill({ category: "ICE", number: "1095", evas: [] }))).status, 400);
    assert.equal((await askStats(env, [{ category: "ICE; DROP", number: "1095", evas: [] }])).status, 400);
    assert.equal((await askStats(env, [{ category: "ICE", number: "1095", evas: ["x"] }])).status, 400);
    assert.equal((await askStats(env, [{ category: "ICE", number: "1095", evas: Array(7).fill("8000115") }])).status, 400);
    const get = await handleRequest(new Request("https://betterbahn-stats.example/train-stats"), env, seenAt);
    assert.equal(get.status, 405);
});

test("rate limits train statistics per app install", async () => {
    const keys = [];
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret, STATS_LIMITER: { limit: async ({ key }) => { keys.push(key); return { success: false }; } } };
    assert.equal((await askStats(env, [])).status, 429);
    assert.deepEqual(keys, ["key-1"]);
});

test("finds a regional train under bahn.de's own category, by run number and stop", async () => {
    const env = { DB: new FakeD1(), TOKEN_SECRET: secret };
    // Stored as "NRE 3185"; the app knows it as "RE" with the run number 3185.
    addRun(env.DB, "2026-10-01", [120, 4, 122, 4, "7", null, 0], { category: "NRE", number: "3185" });
    addRun(env.DB, "2026-10-02", [120, 6, 122, 6, "7", "8", 0], { category: "DRE", number: "3185" });
    // Another regional train with that number that doesn't stop at Fulda, and a long-distance one that does.
    addRun(env.DB, "2026-10-03", [120, 9, 122, 9, "7", null, 0], { category: "NRB", number: "3185" });
    env.DB.db.prepare("UPDATE runs SET stops = ? WHERE key = ?").run(JSON.stringify([["8000999", null, null, 0, 0, "1", null, 0]]), "2026-10-03|NRB|3185");
    addRun(env.DB, "2026-10-04", [120, 30, 122, 30, "7", null, 0], { category: "ICE", number: "3185" });

    const [train] = (await (await askStats(env, [{ category: "RE", number: "3185", evas: [FULDA] }])).json()).trains;
    assert.equal(train.runs, 2);
    assert.deepEqual(train.stops[FULDA].arrival.sort(), [4, 6]);

    // An ICE is only found as an ICE.
    const [ice] = (await (await askStats(env, [{ category: "ICE", number: "3185", evas: [FULDA] }])).json()).trains;
    assert.deepEqual(ice.stops[FULDA].arrival, [30]);
});
