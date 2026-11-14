import assert from "node:assert/strict";
import test from "node:test";
import { deflateRawSync, deflateSync } from "node:zlib";
import { decodeJourney, durationText, journeyPageHTML } from "./journeypage.mjs";
import worker from "./worker.mjs";

const origin = "https://betterbahn.betterbahn.workers.dev";
// 2026-11-20 08:00 UTC = 09:00 in Berlin, as Apple's Date encodes it (seconds since 2001-01-01).
const base = Date.UTC(2026, 10, 20, 8, 0) / 1000 - 978307200;

const station = name => ({ id: name, name, source: "bahnDe" });
const time = (minutes, delay) => ({ planned: base + minutes * 60, actual: delay === undefined ? null : base + (minutes + delay) * 60 });

function leg(overrides) {
    return {
        origin: station("Berlin Hbf"), destination: station("Hannover Hbf"),
        departure: time(0), arrival: time(100),
        departurePlatform: { planned: "11" }, arrivalPlatform: { planned: "9" },
        line: { name: "ICE 1001", product: "highSpeed" }, direction: "Köln Hbf",
        isWalking: false, cancelled: false, remarks: [], messages: [], source: "bahnDe",
        stopovers: [
            { station: station("Berlin Hbf"), departure: time(0), arrivalCancelled: false, departureCancelled: false, access: "normal" },
            { station: station("Wolfsburg Hbf"), arrival: time(50), departure: time(52), arrivalPlatform: { planned: "3" },
                arrivalCancelled: false, departureCancelled: false, access: "normal" },
            { station: station("Hannover Hbf"), arrival: time(100), arrivalCancelled: false, departureCancelled: false, access: "normal" },
        ],
        ...overrides,
    };
}

function payload(journey, compress = deflateRawSync) {
    return compress(Buffer.from(JSON.stringify(journey))).toString("base64url");
}

const journey = {
    source: "bahnDe",
    legs: [
        leg({ arrival: time(100, 7), arrivalPlatform: { planned: "9", actual: "12" } }),
        leg({
            origin: station("Hannover Hbf"), destination: station("Köln Hbf"), departure: time(110), arrival: time(270),
            line: { name: "RE <6>", product: "regionalExpress" }, direction: "Köln Hbf", stopovers: [],
            messages: [{ kind: "notice", text: "Kein WLAN" }],
        }),
    ],
};

const style = "<style>/*page*/</style>";
const footer = "<p>footer</p>";

test("reads the journey the app stores (raw deflate, also zlib)", async () => {
    for (const compress of [deflateRawSync, deflateSync]) {
        const view = await decodeJourney(payload(journey, compress));
        assert.equal(view.legs.length, 2);
        assert.equal(view.legs[0].origin, "Berlin Hbf");
        assert.equal(view.legs[0].departure.planned, Date.UTC(2026, 10, 20, 8, 0));
        assert.equal(view.legs[0].arrival.actual - view.legs[0].arrival.planned, 7 * 60000);
    }
});

test("data that isn't a journey isn't drawn", async () => {
    assert.equal(await decodeJourney("data"), null);
    assert.equal(await decodeJourney("eJzLSM3JyQcABiwCFQ"), null);
    assert.equal(await decodeJourney(payload({ legs: [] })), null);
    assert.equal(await decodeJourney(payload({ legs: [{ origin: station("A") }] })), null);
});

test("a payload that inflates past the limit is refused", async () => {
    const bomb = deflateRawSync(Buffer.alloc(2 * 1024 * 1024, 32)).toString("base64url");
    assert.equal(await decodeJourney(bomb), null);
});

test("the page shows legs, times in Berlin, delays, platforms, stops and the way into the app", async () => {
    const view = await decodeJourney(payload(journey));
    const html = journeyPageHTML("Ab3xK9zz", view, { style, footer, appStoreURL: "https://apps.apple.com/app/id1" });
    assert.match(html, /<title>Berlin Hbf → Köln Hbf – BetterBahn<\/title>/);
    assert.match(html, /Freitag, 20\. November/);
    assert.match(html, /09:00/);
    assert.match(html, /<span class="slight">10:47<\/span> <s>10:40<\/s>/);
    assert.match(html, /Gl\. 12/);
    assert.match(html, /class="gl moved"/);
    assert.match(html, /1 Halt/);
    assert.match(html, /Wolfsburg Hbf/);
    assert.match(html, /Umstieg: 3 Min\./);
    assert.match(html, /Kein WLAN/);
    assert.match(html, /4 Std\. 30 Min\. · 1 Umstieg/);
    assert.match(html, /href="betterbahn:\/\/share\?id=Ab3xK9zz"/);
    assert.match(html, /href="https:\/\/apps\.apple\.com\/app\/id1"/);
    // Text from the data is escaped.
    assert.match(html, /RE &lt;6&gt;/);
    assert.doesNotMatch(html, /RE <6>/);
});

test("walks, cancelled trains and a broken transfer", async () => {
    const view = await decodeJourney(payload({
        source: "bahnDe",
        legs: [
            leg({ cancelled: true, arrival: time(100, 20) }),
            leg({ origin: station("Hannover Hbf"), destination: station("Hannover Hbf Süd"), departure: time(105), arrival: time(110),
                line: null, isWalking: true, stopovers: [] }),
            leg({ origin: station("Hannover Hbf Süd"), departure: time(112), arrival: time(200), stopovers: [] }),
        ],
    }));
    const html = journeyPageHTML("Ab3xK9zz", view, { style, footer });
    assert.match(html, /Fällt aus/);
    assert.match(html, /Fußweg von Hannover Hbf nach Hannover Hbf Süd · 5 Min\./);
    assert.doesNotMatch(html, /App Store/);
});

test("line colors follow the app: only S-Bahn and U-Bahn, only with contrast to white", async () => {
    const colored = (product, feedColorHex) => decodeJourney(payload({
        source: "bahnDe", legs: [leg({ line: { name: "S1", product, feedColorHex } })],
    }));
    assert.equal((await colored("suburban", 0x00658e)).legs[0].color, 0x00658e);
    assert.equal((await colored("suburban", 0xffff00)).legs[0].color, null);
    assert.equal((await colored("highSpeed", 0x00658e)).legs[0].color, null);
    assert.equal((await colored("suburban", undefined)).legs[0].color, null);
});

test("only stops that repeat the leg's start and end are left out of the list", async () => {
    const withoutEnds = await decodeJourney(payload({
        source: "bahnDe",
        legs: [leg({ stopovers: [
            { station: station("Spandau"), arrival: time(10), arrivalCancelled: false, departureCancelled: false, access: "normal" },
            { station: station("Wolfsburg Hbf"), arrival: time(50), arrivalCancelled: false, departureCancelled: false, access: "normal" },
        ] })],
    }));
    const html = journeyPageHTML("Ab3xK9zz", withoutEnds, { style, footer });
    assert.match(html, /2 Halte/);
    assert.match(html, /Spandau/);
});

test("durations", () => {
    assert.equal(durationText(45), "45 Min.");
    assert.equal(durationText(120), "2 Std.");
    assert.equal(durationText(135), "2 Std. 15 Min.");
});

class FakeKV {
    entries = new Map();
    async get(key) { return this.entries.get(key) ?? null; }
}

test("/s/<id> shows the journey for a stored share and keeps the plain page for other data", async () => {
    const environment = { SHARES: new FakeKV() };
    environment.SHARES.entries.set("Ab3xK9zz", payload(journey));
    environment.SHARES.entries.set("Cd4yL0aa", "eJzLSM3JyQcABiwCFQ");

    const page = await worker.fetch(new Request(`${origin}/s/Ab3xK9zz`), environment);
    assert.equal(page.status, 200);
    assert.equal(page.headers.get("Content-Security-Policy"), "default-src 'none'; style-src 'unsafe-inline'");
    assert.match(await page.text(), /Wolfsburg Hbf/);

    const plain = await worker.fetch(new Request(`${origin}/s/Cd4yL0aa`), environment);
    assert.equal(plain.status, 200);
    assert.match(await plain.text(), /In BetterBahn öffnen/);

    const head = await worker.fetch(new Request(`${origin}/s/Ab3xK9zz`, { method: "HEAD" }), environment);
    assert.equal(head.status, 200);
    assert.equal(await head.text(), "");
});
