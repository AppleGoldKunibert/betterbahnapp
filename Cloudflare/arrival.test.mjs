import assert from "node:assert/strict";
import test from "node:test";
import { AFTER_ARRIVAL, parseArrival, renderArrival } from "./arrival.mjs";
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

function bahnDe(body, status = 200) {
    const calls = [];
    const tokens = [];
    const fetchUpstream = async (url, init) => {
        calls.push(url);
        tokens.push(init.headers["X-BetterBahn-Token"]);
        return new Response(JSON.stringify(body), { status });
    };
    return { calls, tokens, fetchUpstream };
}

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

test("the page and its refresh show bahn.de's live arrival, delay and platform", async () => {
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
    assert.match(upstream.calls[0], /^https:\/\/proxy\.test\/web\/api\/reiseloesung\/fahrt\?journeyId=2%7C%23VN/);
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
    assert.equal(quiet.calls.length, 0);

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
