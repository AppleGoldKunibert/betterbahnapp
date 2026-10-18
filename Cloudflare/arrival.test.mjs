import assert from "node:assert/strict";
import test from "node:test";
import { AFTER_ARRIVAL, findTrain, irisStops, parseArrival, renderArrival, shownStops } from "./arrival.mjs";
import { verifyToken } from "./shared/appattest.mjs";
import { handleShare } from "./worker.mjs";

const origin = "https://betterbahn.betterbahn.workers.dev";
const journeyId = "2|#VN#1#ST#1759#PI#0#ZI#1#TA#0#DA#61026#1S#8000261#1T#1756#LS#8000105#LT#2209#PU#80#RT#1#CA#ICE#ZE#1095#ZB#ICE  1095#PC#0#FR#8000261#FT#1756#TO#8000105#TT#2209#";
// 2026-10-06 in Berlin (CEST, UTC+2).
const at = clock => Date.parse(`2026-10-06T${clock}:00+02:00`);

class FakeKV {
    entries = new Map();
    puts = [];
    async get(key) { return this.entries.get(key) ?? null; }
    async put(key, value, options) {
        this.puts.push({ key, value, options });
        this.entries.set(key, value);
    }
}

function env() {
    return { SHARES: new FakeKV(), ALLOW_UNATTESTED: "true", TOKEN_SECRET: "test-secret", BAHNDE_PROXY_URL: "https://proxy.test" };
}

/// What the app sends (`ArrivalShare`): Nürnberg → Frankfurt on ICE 1095.
function arrival(extra = {}) {
    return {
        train: "ICE 1095", product: "highSpeed", journeyId,
        stops: [
            { name: "Nürnberg Hbf", eva: "8000284", arrival: "2026-10-06T17:00:00Z", departure: "2026-10-06T17:02:00Z", platform: "7", cancelled: false },
            { name: "Frankfurt(Main)Hbf", eva: "8000105", arrival: "2026-10-06T20:09:00Z", platform: "8", cancelled: false },
        ],
        ...extra,
    };
}

/// bahn.de's journey details for ICE 1095 München → Frankfurt.
function details({ arrivalRt = "2026-10-06T22:14:00", platformRt = "9" } = {}) {
    return {
        zugName: "ICE 1095",
        himMeldungen: [{ text: "Reparatur am Zug." }],
        halte: [
            { extId: "8000261", name: "München Hbf", gleis: "19", abfahrtsZeitpunkt: "2026-10-06T17:56:00" },
            { extId: "8000284", name: "Nürnberg Hbf", gleis: "7",
                ankunftsZeitpunkt: "2026-10-06T19:00:00", ezAnkunftsZeitpunkt: "2026-10-06T19:05:00",
                abfahrtsZeitpunkt: "2026-10-06T19:02:00", ezAbfahrtsZeitpunkt: "2026-10-06T19:07:00" },
            { extId: "8000105", name: "Frankfurt(Main)Hbf", gleis: "8", ezGleis: platformRt,
                ankunftsZeitpunkt: "2026-10-06T22:09:00", ezAnkunftsZeitpunkt: arrivalRt },
        ],
    };
}

const irisTimetable = (station, stops) => `<?xml version='1.0' encoding='UTF-8'?><timetable station='${station}'>${stops}</timetable>`;

/// IRIS's schedules and changes for ICE 1095 at Nürnberg and Frankfurt (an RE leaves Nürnberg at the same minute).
const irisPlans = {
    "8000284": irisTimetable("Nürnberg Hbf", `<s id="-7-2610061756-5"><tl f="F" t="p" o="80" c="ICE" n="1095"/><ar pt="2610061900" pp="7" ppth="München Hbf"/><dp pt="2610061902" pp="7" ppth="Frankfurt(Main)Hbf"/></s>`
        + `<s id="-9-2610061902-1"><tl f="N" t="p" o="800" c="RE" n="4012"/><dp pt="2610061902" pp="2" l="RE10"/></s>`),
    "8000105": irisTimetable("Frankfurt(Main)Hbf", `<s id="-7-2610061756-9"><tl f="F" t="p" o="80" c="ICE" n="1095"/><ar pt="2610062209" pp="8"/></s>`),
};
const irisChanges = {
    "8000284": irisTimetable("Nürnberg Hbf", `<s id="-7-2610061756-5" eva="8000284">\n<ar ct="2610061905"/>\n<dp ct="2610061907">\n<m t="d" c="34"/>\n</dp>\n</s>`),
    "8000105": irisTimetable("Frankfurt(Main)Hbf", `<s id="-7-2610061756-9" eva="8000105">\n<ar ct="2610062214" cp="9"/>\n</s>`),
};

/// IRIS and our bahn.de server: answers by URL and records each request. IRIS knows nothing unless given.
function upstream({ plans = {}, changes = {}, irisStatus = {}, bahnDe = null, bahnDeStatus = 200 } = {}) {
    const calls = [];
    const tokens = [];
    const fetchUpstream = async (url, init) => {
        calls.push(url);
        const iris = url.match(/^https:\/\/iris\.noncd\.db\.de\/iris-tts\/timetable\/(plan|fchg)\/(\d+)/);
        if (iris) {
            const [, kind, eva] = iris;
            if (irisStatus[eva]) return new Response("", { status: irisStatus[eva], headers: { "Retry-After": "60" } });
            const body = (kind === "plan" ? plans : changes)[eva];
            return new Response(body ?? "", { status: body === undefined ? 404 : 200 });
        }
        tokens.push(init.headers["X-BetterBahn-Token"]);
        return bahnDe === null ? new Response("", { status: 404 }) : new Response(JSON.stringify(bahnDe), { status: bahnDeStatus });
    };
    return { calls, tokens, fetchUpstream };
}

const bahnDe = (body, status = 200) => upstream({ bahnDe: body, bahnDeStatus: status });
const proxyCalls = fake => fake.calls.filter(url => url.startsWith("https://proxy.test/"));

async function share(environment, body, now) {
    const request = new Request(`${origin}/share`, { method: "POST", body: JSON.stringify(body) });
    return handleShare(request, environment, now);
}

test("an arrival link lasts until 2 hours after the arrival, not 30 days", async () => {
    const environment = env();
    const now = at("18:00");
    const response = await share(environment, { data: "eJzLSM3JyQcABiwCFQ", arrival: arrival() }, now);
    assert.equal(response.status, 201);
    const { id, expiresAt } = await response.json();
    assert.equal(Date.parse(expiresAt), at("22:09") + AFTER_ARRIVAL * 1000);
    assert.equal(environment.SHARES.puts[0].options.expirationTtl, (at("22:09") + AFTER_ARRIVAL * 1000 - now) / 1000);

    // The app still gets the journey.
    const read = await handleShare(new Request(`${origin}/share/${id}`), environment, now);
    assert.deepEqual(await read.json(), { data: "eJzLSM3JyQcABiwCFQ" });

    // After that it is gone, even while KV still has it.
    const late = await handleShare(new Request(`${origin}/share/${id}`), environment, at("22:09") + AFTER_ARRIVAL * 1000 + 1000);
    assert.equal(late.status, 404);
    const page = await handleShare(new Request(`${origin}/s/${id}`), environment, at("22:09") + AFTER_ARRIVAL * 1000 + 1000);
    assert.equal(page.status, 404);
    assert.match(await page.text(), /Link abgelaufen/);
});

test("refuses arrivals that aren't one or are long over", async () => {
    const environment = env();
    const now = at("18:00");
    assert.equal((await share(environment, { data: "abc", arrival: { train: "ICE 1" } }, now)).status, 400);
    assert.equal((await share(environment, { data: "abc", arrival: arrival({ stops: [arrival().stops[0]] }) }, now)).status, 400);
    const broken = arrival();
    broken.stops[1].arrival = "tomorrow";
    assert.equal((await share(environment, { data: "abc", arrival: broken }, now)).status, 400);
    assert.equal((await share(environment, { data: "abc", arrival: arrival() }, at("22:09") + AFTER_ARRIVAL * 1000 + 1000)).status, 400);
    assert.equal(environment.SHARES.puts.length, 0);

    // A journey ID or EVA number that isn't one is dropped, not passed on to bahn.de.
    const odd = parseArrival(arrival({ journeyId: "../x", color: -1 }));
    assert.equal(odd.journeyId, null);
    assert.equal(odd.color, null);
});

test("the page and its refresh show DB's live arrival from IRIS, asked per stop", async () => {
    const environment = env();
    const now = at("20:00");
    const { id } = await (await share(environment, { data: "abc", arrival: arrival() }, now)).json();
    const fake = upstream({ plans: irisPlans, changes: irisChanges, bahnDe: details() });

    const view = await (await handleShare(new Request(`${origin}/share/${id}/live`), environment, now, fake)).json();
    assert.equal(view.live, true);
    assert.equal(view.stops[1].arrRt, at("22:14"));
    assert.equal(view.stops[1].platform, "8");
    assert.equal(view.stops[1].platformRt, "9");
    // Nürnberg's own departure, not the RE leaving at the same minute.
    assert.equal(view.stops[0].depRt, at("19:07"));
    assert.equal(view.stops[0].platform, "7");
    // The schedule of the hour each stop is planned in; bahn.de isn't asked.
    assert.ok(fake.calls.includes("https://iris.noncd.db.de/iris-tts/timetable/plan/8000105/261006/22"));
    assert.ok(fake.calls.includes("https://iris.noncd.db.de/iris-tts/timetable/plan/8000284/261006/19"));
    assert.ok(fake.calls.includes("https://iris.noncd.db.de/iris-tts/timetable/fchg/8000105"));
    assert.deepEqual(proxyCalls(fake), []);

    const html = renderArrival(view, now);
    assert.match(html, /<span class="time ontime">22:14<\/span><span class="planned">22:09<\/span>/);
    assert.match(html, /Live-Daten der Deutschen Bahn/);
});

test("IRIS lists only changes: no change counts as on time once the train is about to run", async () => {
    const environment = env();
    const { id } = await (await share(environment, { data: "abc", arrival: arrival() }, at("15:00"))).json();
    const changes = { "8000284": irisTimetable("Nürnberg Hbf", ""), "8000105": irisTimetable("Frankfurt(Main)Hbf", "") };
    const read = async now => (await handleShare(new Request(`${origin}/share/${id}/live`), environment, now,
        upstream({ plans: irisPlans, changes, bahnDe: details() }))).json();

    const running = await read(at("20:00"));
    assert.equal(running.live, true);
    assert.equal(running.stops[1].arrRt, at("22:09"));
    assert.equal(running.stops[1].platformRt, null);

    // More than 2 hours before it leaves Nürnberg nothing is live yet, and bahn.de wouldn't know more.
    const ahead = await read(at("16:30"));
    assert.equal(ahead.live, false);
    assert.equal(ahead.stops[1].arrRt, null);
});

test("a stop IRIS fails for keeps the app's times; IRIS limiting us is logged and bahn.de answers instead", async t => {
    const warnings = t.mock.method(console, "warn", () => {});
    const environment = env();
    const now = at("20:00");
    const { id } = await (await share(environment, { data: "abc", arrival: arrival() }, now)).json();

    const partly = await (await handleShare(new Request(`${origin}/share/${id}/live`), environment, now,
        upstream({ plans: irisPlans, changes: irisChanges, irisStatus: { "8000284": 500 } }))).json();
    assert.equal(partly.live, true);
    assert.equal(partly.stops[1].arrRt, at("22:14"));
    assert.equal(partly.stops[0].depRt, null);

    const limited = upstream({ plans: irisPlans, changes: irisChanges, irisStatus: { "8000105": 429 }, bahnDe: details() });
    const view = await (await handleShare(new Request(`${origin}/share/${id}/live`), environment, now, limited)).json();
    assert.equal(view.live, true);
    assert.deepEqual(view.messages, ["Reparatur am Zug."]);
    assert.equal(proxyCalls(limited).length, 1);

    const logged = warnings.mock.calls.map(call => JSON.parse(call.arguments[0]));
    assert.deepEqual(logged.at(-1), {
        message: "arrival upstream", source: "iris", status: 429, limited: true,
        path: "/iris-tts/timetable/plan/8000105/261006/22", ms: logged.at(-1).ms, retryAfter: "60",
    });
    assert.ok(logged.some(entry => entry.status === 500 && entry.limited === false));
});

test("finds a regional train in IRIS by run number or line", () => {
    const xml = `<timetable station='Hamburg Hbf'><s id="-6711-2610180005-11"><tl f="N" t="p" o="800201" c="RE" n="11293"/><ar pt="2610180124" pp="13D-F" l="RE7" ppth="Kiel Hbf"/></s></timetable>`;
    assert.equal(findTrain(xml, "2610180124", "ar", { train: "RE 7", number: "11293" })?.id, "-6711-2610180005-11");
    assert.equal(findTrain(xml, "2610180124", "ar", { train: "RE 7", number: null })?.id, "-6711-2610180005-11");
    assert.equal(findTrain(xml, "2610180124", "ar", { train: "RE 70", number: "11295" }), null);
    assert.equal(findTrain(xml, "2610180125", "ar", { train: "RE 7", number: "11293" }), null);
});

test("without IRIS the page and its refresh show bahn.de's live arrival, delay and platform", async () => {
    const environment = env();
    const now = at("20:00");
    const { id } = await (await share(environment, { data: "abc", arrival: arrival() }, now)).json();
    const upstream = bahnDe(details());

    const live = await handleShare(new Request(`${origin}/share/${id}/live`), environment, now, upstream);
    assert.equal(live.status, 200);
    const view = await live.json();
    assert.equal(view.live, true);
    assert.deepEqual(view.stops.map(stop => stop.name), ["Nürnberg Hbf", "Frankfurt(Main)Hbf"]);
    assert.equal(view.stops[1].arrRt, at("22:14"));
    assert.equal(view.stops[1].platformRt, "9");
    assert.deepEqual(view.messages, ["Reparatur am Zug."]);
    // Through our bahn.de server, with a token it accepts.
    assert.match(proxyCalls(upstream)[0], /^https:\/\/proxy\.test\/web\/api\/reiseloesung\/fahrt\?journeyId=2%7C%23VN/);
    assert.equal((await verifyToken(upstream.tokens[0], "a", "test-secret", now))?.kid, "arrival-pages");

    const page = await handleShare(new Request(`${origin}/s/${id}`), environment, now, upstream);
    assert.equal(page.status, 200);
    const csp = page.headers.get("Content-Security-Policy");
    assert.match(csp, /script-src 'nonce-[A-Za-z0-9]{8}'/);
    const html = await page.text();
    assert.match(html, /<h1>Frankfurt\(Main\)Hbf<\/h1>/);
    assert.match(html, /<span class="time ontime">22:14<\/span><span class="planned">22:09<\/span>/);
    assert.match(html, /<div class="platform changed"><span>Gleis<\/span><strong>9<\/strong><\/div>/);
    assert.match(html, /statt 8/);
    assert.match(html, /Ankunft in 2 Std\. 14 Min\./);
    assert.match(html, new RegExp(`<script nonce="${csp.match(/nonce-(\w+)/)[1]}">`));
});

test("a train running late keeps its link until 2 hours after its new arrival", async () => {
    const environment = env();
    const now = at("20:00");
    const { id } = await (await share(environment, { data: "abc", arrival: arrival() }, now)).json();
    await handleShare(new Request(`${origin}/share/${id}/live`), environment, now, bahnDe(details({ arrivalRt: "2026-10-06T23:30:00" })));
    const stored = JSON.parse(environment.SHARES.entries.get(id));
    assert.equal(stored.expiresAt, at("23:30") + AFTER_ARRIVAL * 1000);
    assert.equal(environment.SHARES.puts.length, 2);

    // No write while nothing changes.
    await handleShare(new Request(`${origin}/share/${id}/live`), environment, now, bahnDe(details({ arrivalRt: "2026-10-06T23:30:00" })));
    assert.equal(environment.SHARES.puts.length, 2);
});

test("without bahn.de the page shows the times from the app", async () => {
    const environment = env();
    const now = at("20:00");
    const { id } = await (await share(environment, { data: "abc", arrival: arrival() }, now)).json();
    const blocked = await (await handleShare(new Request(`${origin}/share/${id}/live`), environment, now, bahnDe({}, 403))).json();
    assert.equal(blocked.live, false);
    assert.equal(blocked.stops[1].arr, at("22:09"));

    // Another run whose stops don't include the user's: not taken.
    const other = details();
    other.halte[2].extId = "8011160";
    const mismatched = await (await handleShare(new Request(`${origin}/share/${id}/live`), environment, now, bahnDe(other))).json();
    assert.equal(mismatched.live, false);

    // Without our server configured nothing is asked.
    const unconfigured = { ...environment, BAHNDE_PROXY_URL: "" };
    const quiet = bahnDe(details());
    const plain = await (await handleShare(new Request(`${origin}/share/${id}/live`), unconfigured, now, quiet)).json();
    assert.equal(plain.live, false);
    assert.deepEqual(proxyCalls(quiet), []);

    const html = renderArrival(blocked, now);
    assert.match(html, /Fahrplanzeiten, gerade ohne Live-Daten/);
    assert.doesNotMatch(html, /class="pill/);
});

test("the page says when the train leaves, arrived or is cancelled", () => {
    const stops = [
        { name: "Nürnberg Hbf", arr: null, arrRt: null, dep: at("19:02"), depRt: at("19:07"), platform: "7", platformRt: null, cancelled: false },
        { name: "Frankfurt(Main)Hbf", arr: at("22:09"), arrRt: at("22:09"), dep: null, depRt: null, platform: "8", platformRt: null, cancelled: false },
    ];
    const view = { train: "ICE 1095", product: "highSpeed", color: null, live: true, stops, messages: [], updatedAt: at("18:00") };
    assert.match(renderArrival(view, at("18:00")), /Fährt um 19:07 in Nürnberg Hbf ab/);
    assert.match(renderArrival(view, at("18:00")), /<span class="pill ontime">pünktlich<\/span>/);
    assert.match(renderArrival(view, at("22:10")), /Angekommen/);
    const cancelled = { ...view, stops: [stops[0], { ...stops[1], cancelled: true }] };
    assert.match(renderArrival(cancelled, at("20:00")), /Fällt aus/);

    // Nothing from the data ends up as markup.
    const hostile = { ...view, train: "<img src=x>", stops: [stops[0], { ...stops[1], name: "<script>" }] };
    assert.doesNotMatch(renderArrival(hostile, at("20:00")), /<img|<script>/);
});

test("the browser re-renders with the same function", async () => {
    // The page embeds `renderArrival`'s source; it must work on its own.
    const render = new Function(`return ${renderArrival.toString()}`)();
    const view = { train: "RE 3", product: "regional", color: null, live: false, updatedAt: at("18:00"), messages: [],
        stops: [
            { name: "A", arr: null, arrRt: null, dep: at("18:10"), depRt: null, platform: null, platformRt: null, cancelled: false },
            { name: "B", arr: at("18:40"), arrRt: null, dep: null, depRt: null, platform: "2", platformRt: null, cancelled: false },
        ] };
    assert.equal(render(view, at("18:20")), renderArrival(view, at("18:20")));
    assert.match(render(view, at("18:20")), /Ankunft in 20 Min\./);
    assert.match(render(view, at("18:20")), /background:#db1730/);
});

/// ICE 1095 Berlin → Frankfurt with 11 stops, 10 minutes late everywhere by the app's times.
function longRun() {
    const names = ["Berlin Hbf", "Berlin-Spandau", "Stendal Hbf", "Wolfsburg Hbf", "Braunschweig Hbf", "Hildesheim Hbf",
        "Göttingen", "Kassel-Wilhelmshöhe", "Fulda", "Hanau Hbf", "Frankfurt(Main)Hbf"];
    const times = ["16:30", "16:42", "17:20", "17:50", "18:10", "18:35", "19:05", "19:25", "20:00", "20:40", "20:55"];
    return names.map((name, index) => ({
        name, eva: `80000${String(index).padStart(2, "0")}`,
        arr: index ? at(times[index]) : null, arrRt: index ? at(times[index]) + 600_000 : null,
        dep: index < 10 ? at(times[index]) : null, depRt: index < 10 ? at(times[index]) + 600_000 : null,
        platform: null, platformRt: null, cancelled: false,
    }));
}

test("the page lists the next 2 stops and the last 2 before the destination", () => {
    const stops = longRun();
    // 18:15: Braunschweig (18:10, +10) not left yet.
    const shown = shownStops(stops, at("18:15"));
    assert.deepEqual(shown.map(stop => [stop.name, stop.skipped ?? 0]), [
        ["Braunschweig Hbf", 4], ["Hildesheim Hbf", 0], ["Fulda", 2], ["Hanau Hbf", 0], ["Frankfurt(Main)Hbf", 0]]);
    const html = renderArrival({ train: "ICE 1095", product: "highSpeed", color: null, live: true, messages: [],
        from: { name: "Berlin Hbf", dep: stops[0].dep, depRt: stops[0].depRt }, stops: shown, updatedAt: at("18:15") }, at("18:15"));
    assert.match(html, /4 Halte/);
    assert.match(html, /2 Halte/);
    assert.match(html, /von Berlin Hbf/);

    // Before it leaves: where you board and the next stop; near the end the lists meet.
    assert.deepEqual(shownStops(stops, at("16:00")).map(stop => stop.name),
        ["Berlin Hbf", "Berlin-Spandau", "Fulda", "Hanau Hbf", "Frankfurt(Main)Hbf"]);
    assert.deepEqual(shownStops(stops, at("20:20")).map(stop => stop.name), ["Fulda", "Hanau Hbf", "Frankfurt(Main)Hbf"]);
    assert.deepEqual(shownStops(stops, at("23:00")).map(stop => stop.name), ["Fulda", "Hanau Hbf", "Frankfurt(Main)Hbf"]);
});

test("IRIS is asked only for the stops the page may list", async () => {
    // At 18:15 the next stops are Braunschweig (4) and Hildesheim (5); 2 before them in case the train is later
    // than the app knew, and the last 2 before Frankfurt (10).
    const asked = new Set();
    const fetchUpstream = async url => {
        asked.add(Number(url.match(/\/(?:plan|fchg)\/80000(\d\d)/)[1]));
        return new Response("", { status: 404 });
    };
    await irisStops({ train: "ICE 1095", number: "1095", stops: longRun() }, { now: at("18:15"), fetchUpstream });
    assert.deepEqual([...asked].sort((a, b) => a - b), [2, 3, 4, 5, 8, 9, 10]);
});
