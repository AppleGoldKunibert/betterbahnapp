import assert from "node:assert/strict";
import test from "node:test";
import { TOKEN_HEADER, signToken } from "../shared/appattest.mjs";
import { DEFAULT_ADMIN_IDS, UPSTREAM, adminIds, compact, handleRequest } from "./worker.mjs";

const base = "https://betterbahn-positions.example.workers.dev";
const secret = "test-secret";
const env = { TOKEN_SECRET: secret, DB_CLIENT_ID: "client", DB_API_KEY: "key" };
const accessToken = () => signToken({ t: "a", kid: "key", exp: Math.floor(Date.now() / 1000) + 60 }, secret);

// Shortened from a real RIS::Maps answer (3 November 2026).
const RIS_ANSWER = {
    positions: [
        {
            meta: { timeCreated: "2026-11-03T03:23:49.314Z", timeInformation: "2026-11-03T03:23:48Z", correlation: [] },
            journeyID: "20261102-517e7679-d3a4-3e6c-8e95-6556a3dbf9cd",
            administrations: ["80"],
            info: {
                transportAtStart: { type: "HIGH_SPEED_TRAIN", journeyName: "ICE 921", journeyNumber: 921, category: "ICE", label: "" },
                type: "REGULAR",
                origin: { evaNumber: "8002553", name: "Hamburg-Altona" },
                destination: { evaNumber: "8000207", name: "Köln Hbf" },
            },
            longitude: 6.968878333299999, latitude: 50.941489999999995, metaSource: "SENSOR", speed: 26.74,
        },
        {
            meta: { timeCreated: "2026-11-03T03:23:20.944Z", timeInformation: "2026-11-03T03:21:37Z", correlation: [] },
            journeyID: "20261103-7ce51213-41dd-3f72-ab3b-ef825fa4121f",
            administrations: ["800158"],
            info: {
                transportAtStart: { type: "REGIONAL_TRAIN", journeyName: "RE51", journeyNumber: 13051, category: "RE", label: "", line: "RE51" },
                type: "REGULAR",
                origin: { evaNumber: "8010338", name: "Stralsund Hbf" },
                destination: { evaNumber: "8010250", name: "Neustrelitz Hbf" },
            },
            longitude: 13.07381, latitude: 54.20985, direction: 191.0, metaSource: "SIGNALLING",
        },
        { journeyID: "20261103-no-position", info: {} },
    ],
};

function fakeFetch(status = 200, body = RIS_ANSWER) {
    const calls = [];
    const fn = async (url, init) => {
        calls.push({ url, init });
        return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
    };
    fn.calls = calls;
    return fn;
}

function fakeCache() {
    const store = new Map();
    return {
        store,
        match: async request => store.get(request.url)?.clone(),
        put: async (request, response) => { store.set(request.url, response); },
    };
}

async function get(path, { token = true, fetch = fakeFetch(), cache = fakeCache(), environment = env, method = "GET" } = {}) {
    const headers = token ? { [TOKEN_HEADER]: await accessToken() } : {};
    const response = await handleRequest(new Request(base + path, { method, headers }), environment,
        { fetch, cache, now: () => Date.parse("2026-11-03T03:24:00Z") });
    return { response, fetch, cache };
}

test("health answers without upstream or token", async () => {
    const { response, fetch } = await get("/health", { token: false });
    assert.equal(response.status, 200);
    assert.equal(fetch.calls.length, 0);
});

test("rejects unknown paths and non-GET requests", async () => {
    assert.equal((await get("/journeys/x")).response.status, 404);
    assert.equal((await get("/web/api/x")).response.status, 404);
    const post = await get("/journeys", { method: "POST" });
    assert.equal(post.response.status, 405);
    assert.equal(post.fetch.calls.length, 0);
});

test("requires an App Attest token, even with ALLOW_UNATTESTED", async () => {
    for (const environment of [env, { ...env, ALLOW_UNATTESTED: "true" }]) {
        const { response, fetch } = await get("/journeys", { token: false, environment });
        assert.equal(response.status, 401);
        assert.equal(fetch.calls.length, 0);
    }
    const forged = await handleRequest(new Request(base + "/journeys", { headers: { [TOKEN_HEADER]: "forged.token" } }), env,
        { fetch: fakeFetch(), cache: fakeCache() });
    assert.equal(forged.status, 401);
});

test("without the API key nothing is asked", async () => {
    const { response, fetch } = await get("/journeys", { environment: { TOKEN_SECRET: secret } });
    assert.equal(response.status, 503);
    assert.equal(fetch.calls.length, 0);
});

test("asks RIS::Maps with our key and the administrations, and answers the compact list", async () => {
    const { response, fetch } = await get("/journeys");
    assert.equal(response.status, 200);
    assert.equal(fetch.calls.length, 1);
    const { url, init } = fetch.calls[0];
    assert.equal(url, UPSTREAM);
    assert.equal(init.method, "POST");
    assert.equal(init.headers["DB-Client-Id"], "client");
    assert.equal(init.headers["DB-Api-Key"], "key");
    assert.equal(init.headers["RISMAPS-App-Id"], "livemap-WebSdk");
    assert.deepEqual(JSON.parse(init.body), { administrationIDs: DEFAULT_ADMIN_IDS });

    const body = await response.json();
    assert.equal(body.fetchedAt, "2026-11-03T03:24:00.000Z");
    assert.equal(body.trains.length, 2);
    assert.deepEqual(body.trains[0], {
        id: "20261102-517e7679-d3a4-3e6c-8e95-6556a3dbf9cd", category: "ICE", number: 921, name: "ICE 921",
        type: "HIGH_SPEED_TRAIN", origin: "Hamburg-Altona", originEva: "8002553",
        destination: "Köln Hbf", destinationEva: "8000207", lat: 50.941489999999995, lon: 6.968878333299999, speed: 26.74,
        time: "2026-11-03T03:23:48Z", source: "SENSOR",
    });
    assert.equal(body.trains[1].line, "RE51");
    assert.equal(body.trains[1].speed, undefined);
    assert.equal(body.trains[1].source, "SIGNALLING");
});

test("ADMIN_IDS replaces the default administrations", () => {
    assert.deepEqual(adminIds({ ADMIN_IDS: " 80, 800725 ,," }), ["80", "800725"]);
    assert.deepEqual(adminIds({ ADMIN_IDS: "" }), DEFAULT_ADMIN_IDS);
});

test("serves the cached list for TTL without asking again", async () => {
    const cache = fakeCache();
    const fetch = fakeFetch();
    const first = await get("/journeys", { cache, fetch });
    assert.equal(first.response.headers.get("X-Proxy-Cache"), "MISS");
    assert.match(first.response.headers.get("Cache-Control"), /max-age=15/);
    const second = await get("/journeys", { cache, fetch });
    assert.equal(second.response.status, 200);
    assert.equal(second.response.headers.get("X-Proxy-Cache"), "HIT");
    assert.equal(fetch.calls.length, 1);
    assert.equal((await second.response.json()).trains.length, 2);
});

test("errors are not cached; 429 is passed on, others read as unreachable", async () => {
    const cache = fakeCache();
    const limited = await get("/journeys", { cache, fetch: fakeFetch(429, "{}") });
    assert.equal(limited.response.status, 429);
    const failing = await get("/journeys", { cache, fetch: fakeFetch(500, "{}") });
    assert.equal(failing.response.status, 502);
    const garbage = await get("/journeys", { cache, fetch: fakeFetch(200, "<html>") });
    assert.equal(garbage.response.status, 502);
    assert.equal(cache.store.size, 0);
    const down = await get("/journeys", { cache, fetch: async () => { throw new Error("offline"); } });
    assert.equal(down.response.status, 502);
});

test("compact drops entries without a position", () => {
    assert.deepEqual(compact(undefined, 0).trains, []);
    assert.deepEqual(compact([{ journeyID: "x", latitude: "1", longitude: 2 }], 0).trains, []);
});
