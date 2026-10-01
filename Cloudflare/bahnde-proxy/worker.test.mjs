import assert from "node:assert/strict";
import test from "node:test";
import { TOKEN_HEADER, signToken } from "../shared/appattest.mjs";
import { handleRequest, upstreamHeaders } from "./worker.mjs";

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

test("forwards allowed paths with the query unchanged", async () => {
    const fetch = fakeFetch();
    const query = "?journeyId=2%7C%23VN%231%23ST%23&poly=false";
    const response = await handleRequest(new Request(`${base}/web/api/reiseloesung/fahrt${query}`), open, { fetch, cache: null });
    assert.equal(response.status, 200);
    assert.equal(fetch.calls[0].url, `https://www.bahn.de/web/api/reiseloesung/fahrt${query}`);
    assert.equal(await response.text(), '{"groups":[]}');
});

test("sends the DBRIS browser headers", () => {
    const headers = upstreamHeaders();
    assert.equal(headers.Origin, "https://www.bahn.de");
    assert.equal(headers.Referer, "https://www.bahn.de/buchung/fahrplan/suche");
    assert.match(headers["User-Agent"], /^Mozilla\/5\.0 .*Chrome\/\d+\.0\.\d+\.\d+ /);
    assert.match(headers["x-correlation-id"], /^[0-9a-f-]{36}_[0-9a-f-]{36}$/);
});

test("rejects unknown paths and non-GET requests", async () => {
    const fetch = fakeFetch();
    const paths = ["/", "/web/api/", "/web/api/angebote/fahrplan", "/web/api/../x", "/other", "/web/api/constructor",
        "/web/api/angebote/verbindung/not-a-uuid", "/web/api/angebote/verbindung/../../buchung/auftrag/X",
        "/timetables/v1/plan/8000105", "/timetables/v1/fchg/8000105/../x"];
    for (const path of paths) {
        const response = await handleRequest(new Request(base + path), open, { fetch, cache: null });
        assert.equal(response.status, 404, path);
    }
    const post = await handleRequest(new Request(`${base}/web/api/reiseloesung/orte`, { method: "POST" }), open, { fetch, cache: null });
    assert.equal(post.status, 405);
    assert.equal(fetch.calls.length, 0);
});

test("requires an App Attest token", async () => {
    const fetch = fakeFetch();
    const url = `${base}/web/api/reiseloesung/orte?suchbegriff=Frankfurt`;
    const env = { TOKEN_SECRET: "secret" };
    assert.equal((await handleRequest(new Request(url), env, { fetch, cache: null })).status, 401);
    const wrong = new Request(url, { headers: { [TOKEN_HEADER]: await accessToken("other") } });
    assert.equal((await handleRequest(wrong, env, { fetch, cache: null })).status, 401);
    const ok = await handleRequest(new Request(url, { headers: { [TOKEN_HEADER]: await accessToken("secret") } }), env, { fetch, cache: null });
    assert.equal(ok.status, 200);
    assert.equal(fetch.calls.length, 1);
});

test("forwards shared connections by their vbid", async () => {
    const fetch = fakeFetch(200, '{"hinfahrtRecon":"x"}');
    const vbid = "aaae3fa2-4333-4b5c-9d6e-0123456789ab";
    const response = await handleRequest(new Request(`${base}/web/api/angebote/verbindung/${vbid}`), open, { fetch, cache: null });
    assert.equal(response.status, 200);
    assert.equal(fetch.calls[0].url, `https://www.bahn.de/web/api/angebote/verbindung/${vbid}`);
});

test("forwards Timetables with the API key from the secrets, only with a token", async () => {
    const fetch = fakeFetch(200, "<timetable/>");
    const env = { ...open, TOKEN_SECRET: "secret", DB_CLIENT_ID: "client", DB_API_KEY: "key" };
    const url = `${base}/timetables/v1/plan/8000105/261001/14`;
    // Never without a token, not even during the rollout: it spends our API key.
    assert.equal((await handleRequest(new Request(url), env, { fetch, cache: null })).status, 401);
    const request = new Request(`${url}?ignored=1`, { headers: { [TOKEN_HEADER]: await accessToken("secret") } });
    const response = await handleRequest(request, env, { fetch, cache: null });
    assert.equal(response.status, 200);
    assert.equal(fetch.calls[0].url, "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1/plan/8000105/261001/14");
    assert.equal(fetch.calls[0].init.headers["DB-Api-Key"], "key");
    assert.equal(fetch.calls[0].init.headers["DB-Client-Id"], "client");
    const missing = await handleRequest(new Request(url, { headers: { [TOKEN_HEADER]: await accessToken("secret") } }),
        { TOKEN_SECRET: "secret" }, { fetch, cache: null });
    assert.equal(missing.status, 503);
});

test("caches successful answers per route TTL", async () => {
    const fetch = fakeFetch();
    const cache = fakeCache();
    const url = `${base}/web/api/reisebegleitung/wagenreihung/vehicle-sequence?number=117`;
    const first = await handleRequest(new Request(url), open, { fetch, cache });
    assert.equal(first.headers.get("X-Proxy-Cache"), "MISS");
    assert.equal(first.headers.get("Cache-Control"), "public, max-age=120");
    const second = await handleRequest(new Request(url), open, { fetch, cache });
    assert.equal(second.headers.get("X-Proxy-Cache"), "HIT");
    assert.equal(await second.text(), '{"groups":[]}');
    assert.equal(fetch.calls.length, 1);
});

test("passes blocks through uncached", async () => {
    const fetch = fakeFetch(403, '{"status":"ERROR","code":"OPS_BLOCKED"}');
    const cache = fakeCache();
    const url = `${base}/web/api/reiseloesung/abfahrten?ortExtId=8000105`;
    const response = await handleRequest(new Request(url), open, { fetch, cache });
    assert.equal(response.status, 403);
    assert.match(await response.text(), /OPS_BLOCKED/);
    assert.equal(cache.store.size, 0);
});

test("answers the health check without calling bahn.de", async () => {
    const fetch = fakeFetch();
    const response = await handleRequest(new Request(`${base}/health`), {}, { fetch, cache: null });
    assert.equal(response.status, 200);
    assert.equal(fetch.calls.length, 0);
});
