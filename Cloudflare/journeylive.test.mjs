import assert from "node:assert/strict";
import test from "node:test";
import { deflateRawSync } from "node:zlib";
import { decodeJourney, journeyPageHTML, renderJourney } from "./journeypage.mjs";
import { liveJourney } from "./journeylive.mjs";
import { handleShare } from "./worker.mjs";

const origin = "https://betterbahn.betterbahn.workers.dev";
// 2026-10-06 in Berlin (CEST, UTC+2).
const at = clock => Date.parse(`2026-10-06T${clock}:00+02:00`);
// Apple's `Date`: seconds since 2001-01-01.
const apple = ms => (ms - 978307200000) / 1000;
const stamp = (clock, delay) => ({ planned: apple(at(clock)), actual: delay === undefined ? null : apple(at(clock) + delay * 60000) });
const station = (name, eva) => ({ id: eva, name, evaNumber: eva, source: "bahnDe" });
const flags = { arrivalCancelled: false, departureCancelled: false, access: "normal" };

/// What the app shared: ICE 1095 Nürnberg → Frankfurt, then an RE 3 to Mainz, a transfer of 11 minutes.
const shared = {
    source: "bahnDe",
    legs: [
        {
            origin: station("Nürnberg Hbf", "8000284"), destination: station("Frankfurt(Main)Hbf", "8000105"),
            departure: stamp("19:02"), arrival: stamp("22:09"),
            departurePlatform: { planned: "7" }, arrivalPlatform: { planned: "8" },
            line: { name: "ICE 1095", number: "1095", product: "highSpeed" }, direction: "Hamburg-Altona",
            isWalking: false, cancelled: false, remarks: [], messages: [], source: "bahnDe",
            stopovers: [
                { station: station("Nürnberg Hbf", "8000284"), departure: stamp("19:02"), departurePlatform: { planned: "7" }, ...flags },
                { station: station("Frankfurt(Main)Hbf", "8000105"), arrival: stamp("22:09"), arrivalPlatform: { planned: "8" }, ...flags },
            ],
        },
        {
            origin: station("Frankfurt(Main)Hbf", "8000105"), destination: station("Mainz Hbf", "8000240"),
            departure: stamp("22:20"), arrival: stamp("22:58"),
            departurePlatform: { planned: "3" }, arrivalPlatform: { planned: "5" },
            line: { name: "RE 3", tripNumber: "4711", product: "regionalExpress" }, direction: "Mainz Hbf",
            isWalking: false, cancelled: false, remarks: [], messages: [], source: "bahnDe", stopovers: [],
        },
    ],
};

const payload = journey => deflateRawSync(Buffer.from(JSON.stringify(journey))).toString("base64url");
const irisTimetable = (eva, stops) => `<?xml version='1.0' encoding='UTF-8'?><timetable station='${eva}'>${stops}</timetable>`;
// DB's schedule and changes for the ICE: 5 and 7 minutes late at Nürnberg, 5 minutes late in Frankfurt on track 9.
const plans = {
    "8000284": irisTimetable("Nürnberg Hbf", `<s id="-7-2610061756-5"><tl f="F" t="p" o="80" c="ICE" n="1095"/><ar pt="2610061900" pp="7"/><dp pt="2610061902" pp="7"/></s>`),
    "8000105": irisTimetable("Frankfurt(Main)Hbf", `<s id="-7-2610061756-9"><tl f="F" t="p" o="80" c="ICE" n="1095"/><ar pt="2610062209" pp="8"/></s>`),
};
const changes = {
    "8000284": irisTimetable("Nürnberg Hbf", `<s id="-7-2610061756-5" eva="8000284"><ar ct="2610061905"/><dp ct="2610061907"/></s>`),
    "8000105": irisTimetable("Frankfurt(Main)Hbf", `<s id="-7-2610061756-9" eva="8000105"><ar ct="2610062214" cp="9"/></s>`),
};

/// IRIS answering from the tables above (404 for what it doesn't know); records every request.
function iris({ status = {} } = {}) {
    const calls = [];
    const fetchUpstream = async url => {
        calls.push(url);
        const [, kind, eva] = url.match(/\/(plan|fchg)\/(\d+)/);
        if (status[eva]) return new Response("", { status: status[eva] });
        const body = (kind === "plan" ? plans : changes)[eva];
        return new Response(body ?? "", { status: body === undefined ? 404 : 200 });
    };
    return { calls, fetchUpstream };
}

class FakeKV {
    entries = new Map();
    async get(key) { return this.entries.get(key) ?? null; }
}

class FakeCache {
    entries = new Map();
    async match(request) { return this.entries.get(request.url)?.clone(); }
    async put(request, response) { this.entries.set(request.url, response); }
}

test("a train's live times, platform and the transfer into the next one go into the shared journey", async () => {
    const view = await decodeJourney(payload(shared));
    const fake = iris();
    const live = await liveJourney(view, at("20:00"), { fetchUpstream: fake.fetchUpstream });
    assert.equal(live.live, true);
    assert.equal(live.done, false);
    assert.equal(live.updatedAt, at("20:00"));

    const ice = live.legs[0];
    assert.equal(ice.departure.actual, at("19:07"));
    assert.equal(ice.arrival.actual, at("22:14"));
    assert.equal(ice.arrival.planned, at("22:09"));
    assert.equal(ice.arrivalPlatform.planned, "8");
    assert.equal(ice.arrivalPlatform.actual, "9");
    assert.equal(ice.stops.length, 2);
    // The RE isn't in IRIS: it keeps what the app shared.
    assert.equal(live.legs[1].departure.actual, null);

    const html = renderJourney(live);
    assert.match(html, /<span class="ontime">22:14<\/span> <s>22:09<\/s>/);
    assert.match(html, /class="gl moved">Gl\. 9</);
    assert.match(html, /Umstieg: 6 Min\./);
    assert.match(html, /Live-Daten der Deutschen Bahn · Stand 20:00/);
    // The shared journey itself stays as it was.
    assert.equal(view.legs[0].arrival.actual, null);
});

test("a train on time hours before it leaves is live too: DB knows it, it just reports no change", async () => {
    const view = await decodeJourney(payload(shared));
    const quiet = async url => {
        const [, kind, eva] = url.match(/\/(plan|fchg)\/(\d+)/);
        const body = kind === "plan" ? plans[eva] : irisTimetable(eva, "");
        return new Response(body ?? "", { status: body === undefined ? 404 : 200 });
    };
    const live = await liveJourney(view, at("10:00"), { fetchUpstream: quiet });
    assert.equal(live.live, true);
    assert.equal(live.legs[0].arrival.actual, null);
    assert.match(renderJourney(live), /Live-Daten der Deutschen Bahn · Stand 10:00/);
});

test("trains that have arrived or won't run for a long time aren't asked, a finished journey asks nothing", async () => {
    const view = await decodeJourney(payload(shared));
    const fake = iris();
    // 23:30: both trains arrived over 10 minutes ago, the journey has been over for more than 30.
    const over = await liveJourney(view, at("23:30"), { fetchUpstream: fake.fetchUpstream });
    assert.equal(over.done, true);
    assert.equal(over.live, false);
    assert.deepEqual(fake.calls, []);
    assert.equal(over.legs[0].arrival.actual, null);

    // 22:30: the ICE arrived 16 minutes ago, only the RE is asked (and IRIS doesn't know it).
    const later = await liveJourney(view, at("22:30"), { fetchUpstream: fake.fetchUpstream });
    assert.equal(later.done, false);
    assert.equal(later.live, false);
    assert.ok(fake.calls.every(url => !url.includes("/8000284")), "Nürnberg isn't asked for the ICE any more");
});

test("when DB can't be asked the page keeps the times it has, and what failed is logged", async t => {
    t.mock.method(console, "warn", () => {});
    const view = await decodeJourney(payload(shared));
    const fake = iris({ status: { 8000105: 503 } });
    const live = await liveJourney(view, at("20:00"), { fetchUpstream: fake.fetchUpstream });
    assert.equal(live.live, false);
    assert.equal(live.done, false);
    assert.equal(live.legs[0].arrival.actual, null);
    assert.equal(renderJourney(live).includes("Stand: Zeitpunkt des Teilens."), true);
});

test("the browser draws the page with the same function", async () => {
    const view = await decodeJourney(payload(shared));
    const live = await liveJourney(view, at("20:00"), { fetchUpstream: iris().fetchUpstream });
    const render = new Function(`return ${renderJourney.toString()}`)();
    assert.equal(render(live), renderJourney(live));
    assert.equal(render(view), renderJourney(view));
});

test("the page asks for new times every minute while it is visible, and keeps opened stop lists", async () => {
    const view = await decodeJourney(payload(shared));
    const html = journeyPageHTML("Ab3xK9zz", view, { style: "", footer: "", nonce: "n0nce123" });
    assert.match(html, /<script nonce="n0nce123">/);
    assert.match(html, /setInterval\(refresh, 60000\)/);
    assert.match(html, /if \(document\.hidden\) return;/);
    assert.match(html, /details\.open = open\[index\] === true/);
    assert.match(html, /<div id="journey">/);
    // Without a nonce (no script allowed) the page is the shared state.
    assert.doesNotMatch(journeyPageHTML("Ab3xK9zz", view, { style: "", footer: "" }), /<script/);
});

test("/share/<id>/live answers for a journey link, once a minute per link however many read it", async () => {
    const environment = { SHARES: new FakeKV() };
    environment.SHARES.entries.set("Ab3xK9zz", payload(shared));
    const fake = iris();
    const cache = new FakeCache();
    const read = now => handleShare(new Request(`${origin}/share/Ab3xK9zz/live`), environment, now,
        { fetchUpstream: fake.fetchUpstream, cache });

    const first = await read(at("20:00"));
    assert.equal(first.status, 200);
    assert.equal(first.headers.get("Cache-Control"), "no-store");
    const body = await first.json();
    assert.equal(body.legs[0].arrival.actual, at("22:14"));
    const asked = fake.calls.length;
    assert.ok(asked > 0);

    // The next reader within the minute gets the same answer without asking DB again.
    const second = await (await read(at("20:00") + 20_000)).json();
    assert.deepEqual(second, body);
    assert.equal(fake.calls.length, asked);

    // A minute later nobody has it cached any more: DB is asked again.
    cache.entries.clear();
    await read(at("20:01") + 5_000);
    assert.ok(fake.calls.length > asked);
});

test("/share/<id>/live for a journey link without a cache and for links that don't exist", async () => {
    const environment = { SHARES: new FakeKV() };
    environment.SHARES.entries.set("Ab3xK9zz", payload(shared));
    environment.SHARES.entries.set("Cd4yL0aa", "eJzLSM3JyQcABiwCFQ");
    const read = id => handleShare(new Request(`${origin}/share/${id}/live`), environment, at("20:00"),
        { fetchUpstream: iris().fetchUpstream });
    assert.equal((await read("Ab3xK9zz")).status, 200);
    assert.equal((await read("Zz9yX8ww")).status, 404);
    // Data that isn't a journey has nothing to refresh.
    assert.equal((await read("Cd4yL0aa")).status, 404);
    const post = await handleShare(new Request(`${origin}/share/Ab3xK9zz/live`, { method: "POST" }), environment, at("20:00"), {});
    assert.equal(post.status, 405);
});
