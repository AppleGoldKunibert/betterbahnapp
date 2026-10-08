import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { signToken } from "../shared/appattest.mjs";
import { berlinToUnix, handleRequest, journeyFields, parseJourney, processDueRuns, runKey } from "./worker.mjs";

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
