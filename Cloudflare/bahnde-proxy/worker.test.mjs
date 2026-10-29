import assert from "node:assert/strict";
import test from "node:test";
import { TOKEN_HEADER, signToken } from "../shared/appattest.mjs";
import { handleRequest } from "./worker.mjs";

const base = "https://betterbahn-bahnde.example.workers.dev";
// Routing tests run like the rollout, without App Attest tokens.
const open = { ALLOW_UNATTESTED: "true" };
const accessToken = secret => signToken({ t: "a", kid: "key", exp: Math.floor(Date.now() / 1000) + 60 }, secret);

function fakeFetch(status = 200, body = '{"groups":[]}') {
    const calls = [];
    const fn = async (url, init) => {
        calls.push({ url, init });
        return new Response(body, { status, headers: { "Content-Type": "application/json" } });
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

test("rejects unknown paths and non-GET requests", async () => {
    const fetch = fakeFetch();
    // bahn.de's paths are gone: bahn.de refuses Workers, the app asks it through Server/bahnde-proxy.
    const paths = ["/", "/other", "/web/api/reiseloesung/orte", "/web/api/reiseloesung/fahrt",
        "/web/api/reisebegleitung/wagenreihung/vehicle-sequence", "/web/api/angebote/verbindung/aaae3fa2-4333-4b5c-9d6e-0123456789ab",
        "/timetables/v1/", "/timetables/v1/plan/8000105", "/timetables/v1/fchg/8000105/../x", "/timetables/v1/station/Hamburg"];
    for (const path of paths) {
        const response = await handleRequest(new Request(base + path), open, { fetch, cache: null });
        assert.equal(response.status, 404, path);
    }
    const post = await handleRequest(new Request(`${base}/timetables/v1/fchg/8000105`, { method: "POST" }), open, { fetch, cache: null });
    assert.equal(post.status, 405);
    assert.equal(fetch.calls.length, 0);
});

const IRIS = "https://iris.noncd.db.de/iris-tts/timetable/";
const MARKETPLACE = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1/";
const timetablesEnv = { ...open, TOKEN_SECRET: "secret", DB_CLIENT_ID: "client", DB_API_KEY: "key" };
const timetablesRequest = async path => new Request(`${base}/timetables/v1/${path}`, { headers: { [TOKEN_HEADER]: await accessToken("secret") } });

/// Answers per upstream host: a status, a body, or "down" for a network error.
function fakeTimetables({ iris = [200, "<timetable/>"], marketplace = [200, "<timetable/>"] } = {}) {
    const calls = [];
    const fn = async (url, init) => {
        calls.push({ url, init });
        const [status, body] = url.startsWith(IRIS) ? iris : marketplace;
        if (status === "down") throw new Error("unreachable");
        return new Response(body, { status, headers: { "Content-Type": "application/xml" } });
    };
    fn.calls = calls;
    return fn;
}

test("Timetables needs an App Attest token, it spends our API key", async () => {
    const fetch = fakeTimetables();
    const response = await handleRequest(new Request(`${base}/timetables/v1/plan/8000105/261001/14`), timetablesEnv, { fetch, cache: null });
    assert.equal(response.status, 401);
    assert.equal(fetch.calls.length, 0);
});

test("Timetables asks the keyless IRIS first and never the Marketplace while it answers", async () => {
    const fetch = fakeTimetables({ iris: [200, "<timetable>iris</timetable>"] });
    const response = await handleRequest(await timetablesRequest("plan/8000105/261001/14?ignored=1"), timetablesEnv, { fetch, cache: null });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "<timetable>iris</timetable>");
    assert.deepEqual(fetch.calls.map(call => call.url), [`${IRIS}plan/8000105/261001/14`]);
    assert.equal(fetch.calls[0].init.headers["DB-Api-Key"], undefined);
});

test("Timetables falls back to the Marketplace with the key when IRIS fails", async () => {
    for (const iris of [[503, "down"], [429, "slow down"], ["down"], [500, "x"]]) {
        const fetch = fakeTimetables({ iris, marketplace: [200, "<timetable>marketplace</timetable>"] });
        const response = await handleRequest(await timetablesRequest("fchg/8000105"), timetablesEnv, { fetch, cache: null });
        assert.equal(response.status, 200, String(iris[0]));
        assert.equal(await response.text(), "<timetable>marketplace</timetable>");
        assert.deepEqual(fetch.calls.map(call => call.url), [`${IRIS}fchg/8000105`, `${MARKETPLACE}fchg/8000105`]);
        assert.equal(fetch.calls[1].init.headers["DB-Api-Key"], "key");
        assert.equal(fetch.calls[1].init.headers["DB-Client-Id"], "client");
    }
});

test("Timetables passes the Marketplace error on when both fail", async () => {
    const fetch = fakeTimetables({ iris: [503, "down"], marketplace: [429, "quota"] });
    const response = await handleRequest(await timetablesRequest("fchg/8000105"), timetablesEnv, { fetch, cache: null });
    assert.equal(response.status, 429);
    assert.equal(await response.text(), "quota");
    assert.equal((await handleRequest(await timetablesRequest("fchg/8000105"), timetablesEnv,
        { fetch: fakeTimetables({ iris: ["down"], marketplace: ["down"] }), cache: null })).status, 502);
});

test("Timetables takes IRIS's 'no data' answers without spending the Marketplace", async () => {
    for (const status of [400, 404, 410]) {
        const fetch = fakeTimetables({ iris: [status, "none"] });
        const response = await handleRequest(await timetablesRequest("fchg/8000105"), timetablesEnv, { fetch, cache: null });
        assert.equal(response.status, status);
        assert.equal(fetch.calls.length, 1);
    }
});

test("Timetables works with IRIS alone when the API key is not configured", async () => {
    const fetch = fakeTimetables();
    const env = { ...open, TOKEN_SECRET: "secret" };
    assert.equal((await handleRequest(await timetablesRequest("station/8002549"), env, { fetch, cache: null })).status, 200);
    const down = fakeTimetables({ iris: [503, "down"] });
    assert.equal((await handleRequest(await timetablesRequest("station/8002549"), env, { fetch: down, cache: null })).status, 503);
    assert.equal(down.calls.length, 1);
});

test("Timetables answers are cached whichever source gave them", async () => {
    const fetch = fakeTimetables();
    const cache = fakeCache();
    const first = await handleRequest(await timetablesRequest("fchg/8000105"), timetablesEnv, { fetch, cache });
    assert.equal(first.headers.get("X-Proxy-Cache"), "MISS");
    assert.equal(first.headers.get("Cache-Control"), "public, max-age=30");
    const second = await handleRequest(await timetablesRequest("fchg/8000105"), timetablesEnv, { fetch, cache });
    assert.equal(second.headers.get("X-Proxy-Cache"), "HIT");
    assert.equal(fetch.calls.length, 1);
    const failing = fakeCache();
    await handleRequest(await timetablesRequest("fchg/8000105"), timetablesEnv,
        { fetch: fakeTimetables({ iris: [503, "x"], marketplace: [429, "x"] }), cache: failing });
    assert.equal(failing.store.size, 0);
});

test("answers the health check without calling upstream", async () => {
    const fetch = fakeFetch();
    const response = await handleRequest(new Request(`${base}/health`), {}, { fetch, cache: null });
    assert.equal(response.status, 200);
    assert.equal(fetch.calls.length, 0);
});
