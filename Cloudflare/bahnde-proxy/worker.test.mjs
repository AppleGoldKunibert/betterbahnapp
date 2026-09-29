import assert from "node:assert/strict";
import test from "node:test";
import { handleRequest, upstreamHeaders } from "./worker.mjs";

const base = "https://betterbahn-bahnde.example.workers.dev";

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
    const response = await handleRequest(new Request(`${base}/web/api/reiseloesung/fahrt${query}`), {}, { fetch, cache: null });
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
    for (const path of ["/", "/web/api/", "/web/api/angebote/fahrplan", "/web/api/../x", "/other"]) {
        const response = await handleRequest(new Request(base + path), {}, { fetch, cache: null });
        assert.equal(response.status, 404, path);
    }
    const post = await handleRequest(new Request(`${base}/web/api/reiseloesung/orte`, { method: "POST" }), {}, { fetch, cache: null });
    assert.equal(post.status, 405);
    assert.equal(fetch.calls.length, 0);
});

test("requires the token when PROXY_TOKEN is set", async () => {
    const fetch = fakeFetch();
    const url = `${base}/web/api/reiseloesung/orte?suchbegriff=Frankfurt`;
    const env = { PROXY_TOKEN: "secret" };
    assert.equal((await handleRequest(new Request(url), env, { fetch, cache: null })).status, 401);
    const ok = await handleRequest(new Request(url, { headers: { "X-BetterBahn-Token": "secret" } }), env, { fetch, cache: null });
    assert.equal(ok.status, 200);
    assert.equal(fetch.calls.length, 1);
});

test("caches successful answers per route TTL", async () => {
    const fetch = fakeFetch();
    const cache = fakeCache();
    const url = `${base}/web/api/reisebegleitung/wagenreihung/vehicle-sequence?number=117`;
    const first = await handleRequest(new Request(url), {}, { fetch, cache });
    assert.equal(first.headers.get("X-Proxy-Cache"), "MISS");
    assert.equal(first.headers.get("Cache-Control"), "public, max-age=120");
    const second = await handleRequest(new Request(url), {}, { fetch, cache });
    assert.equal(second.headers.get("X-Proxy-Cache"), "HIT");
    assert.equal(await second.text(), '{"groups":[]}');
    assert.equal(fetch.calls.length, 1);
});

test("passes blocks through uncached", async () => {
    const fetch = fakeFetch(403, '{"status":"ERROR","code":"OPS_BLOCKED"}');
    const cache = fakeCache();
    const url = `${base}/web/api/reiseloesung/abfahrten?ortExtId=8000105`;
    const response = await handleRequest(new Request(url), {}, { fetch, cache });
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
