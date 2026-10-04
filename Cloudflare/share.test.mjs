import assert from "node:assert/strict";
import test from "node:test";
import { signToken } from "./shared/appattest.mjs";
import worker, { MAX_SHARE_DATA_LENGTH, SHARE_TTL, handleShare, randomID } from "./worker.mjs";

const origin = "https://betterbahn.betterbahn.workers.dev";
const secret = "test-secret";

class FakeKV {
    entries = new Map();
    puts = [];
    async get(key) { return this.entries.get(key) ?? null; }
    async put(key, value, options) {
        this.puts.push({ key, value, options });
        this.entries.set(key, value);
    }
}

class FakeLimiter {
    constructor(limit) { this.limit_ = limit; this.keys = []; }
    async limit({ key }) {
        this.keys.push(key);
        return { success: this.keys.filter(k => k === key).length <= this.limit_ };
    }
}

function env(extra = {}) {
    return { SHARES: new FakeKV(), TOKEN_SECRET: secret, ...extra };
}

async function token(kid = "key-1", exp = Math.floor(Date.now() / 1000) + 3600) {
    return signToken({ t: "a", kid, exp }, secret);
}

async function create(environment, body, headers = {}) {
    return worker.fetch(new Request(`${origin}/share`, {
        method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body),
    }), environment);
}

test("stores a journey with a TTL and returns a short link that resolves to it", async () => {
    const environment = env();
    const response = await create(environment, { data: "eJzLSM3JyQcABiwCFQ" }, { "X-BetterBahn-Token": await token() });
    assert.equal(response.status, 201);
    const { id, url, expiresAt } = await response.json();
    assert.match(id, /^[A-Za-z0-9]{8}$/);
    assert.equal(url, `${origin}/s/${id}`);
    assert.ok(Date.parse(expiresAt) > Date.now());
    assert.deepEqual(environment.SHARES.puts[0].options, { expirationTtl: SHARE_TTL });

    const read = await worker.fetch(new Request(`${origin}/share/${id}`), environment);
    assert.equal(read.status, 200);
    assert.deepEqual(await read.json(), { data: "eJzLSM3JyQcABiwCFQ" });
});

test("refuses to store without a valid App Attest token", async () => {
    const environment = env();
    assert.equal((await create(environment, { data: "abc" })).status, 401);
    assert.equal((await create(environment, { data: "abc" }, { "X-BetterBahn-Token": "forged.token" })).status, 401);
    const expired = await token("key-1", Math.floor(Date.now() / 1000) - 1);
    assert.equal((await create(environment, { data: "abc" }, { "X-BetterBahn-Token": expired })).status, 401);
    assert.equal(environment.SHARES.puts.length, 0);

    // During the rollout, apps without App Attest may still create links.
    assert.equal((await create(env({ ALLOW_UNATTESTED: "true" }), { data: "abc" })).status, 201);
});

test("rate limits per app install", async () => {
    const environment = env({ SHARE_CREATE_LIMITER: new FakeLimiter(2) });
    const headers = { "X-BetterBahn-Token": await token("key-1") };
    assert.equal((await create(environment, { data: "a" }, headers)).status, 201);
    assert.equal((await create(environment, { data: "b" }, headers)).status, 201);
    assert.equal((await create(environment, { data: "c" }, headers)).status, 429);
    assert.equal((await create(environment, { data: "d" }, { "X-BetterBahn-Token": await token("key-2") })).status, 201);
    assert.deepEqual(environment.SHARE_CREATE_LIMITER.keys, ["key-1", "key-1", "key-1", "key-2"]);
});

test("only accepts base64url data up to the app's size limit", async () => {
    const environment = env({ ALLOW_UNATTESTED: "true" });
    assert.equal((await create(environment, { data: "<script>" })).status, 400);
    assert.equal((await create(environment, { data: 42 })).status, 400);
    assert.equal((await create(environment, {})).status, 400);
    assert.equal((await create(environment, { data: "A".repeat(MAX_SHARE_DATA_LENGTH + 1) })).status, 413);
    assert.equal((await create(environment, { data: "A".repeat(MAX_SHARE_DATA_LENGTH) })).status, 201);
    const invalid = await worker.fetch(new Request(`${origin}/share`, { method: "POST", body: "{" }), environment);
    assert.equal(invalid.status, 400);
    assert.equal((await worker.fetch(new Request(`${origin}/share`), environment)).status, 405);
});

test("never overwrites an existing link", async () => {
    const environment = env({ ALLOW_UNATTESTED: "true" });
    const first = await (await create(environment, { data: "first" })).json();
    // Pretend every free ID is taken except by retrying.
    let calls = 0;
    const get = environment.SHARES.get.bind(environment.SHARES);
    environment.SHARES.get = async key => (calls++ === 0 ? "taken" : get(key));
    const second = await (await create(environment, { data: "second" })).json();
    assert.equal(calls, 2);
    assert.notEqual(first.id, second.id);
    assert.equal(await get(first.id), "first");
});

test("unknown, expired and malformed IDs are 404", async () => {
    const environment = env();
    assert.equal((await worker.fetch(new Request(`${origin}/share/Ab3xK9zz`), environment)).status, 404);
    assert.equal((await worker.fetch(new Request(`${origin}/share/Ab3xK9zz/extra`), environment)).status, 404);
    assert.equal((await worker.fetch(new Request(`${origin}/share/abc`), environment)).status, 404);
});

test("the link's page offers to open the app, or says the link expired", async () => {
    const environment = env();
    environment.SHARES.entries.set("Ab3xK9zz", "data");
    const page = await worker.fetch(new Request(`${origin}/s/Ab3xK9zz`), environment);
    assert.equal(page.status, 200);
    assert.match(page.headers.get("Content-Type"), /text\/html/);
    const html = await page.text();
    assert.match(html, /href="betterbahn:\/\/share\?id=Ab3xK9zz"/);
    assert.doesNotMatch(html, /App Store/);

    const withStore = await worker.fetch(new Request(`${origin}/s/Ab3xK9zz`), { ...environment, APP_STORE_URL: "https://apps.apple.com/app/id1" });
    assert.match(await withStore.text(), /href="https:\/\/apps\.apple\.com\/app\/id1"/);

    const expired = await worker.fetch(new Request(`${origin}/s/Zz9yX8ww`), environment);
    assert.equal(expired.status, 404);
    assert.match(await expired.text(), /Link abgelaufen/);
});

test("reads are rate limited per IP", async () => {
    const environment = env({ SHARE_READ_LIMITER: new FakeLimiter(1) });
    const request = () => new Request(`${origin}/share/Ab3xK9zz`, { headers: { "CF-Connecting-IP": "203.0.113.1" } });
    assert.equal((await worker.fetch(request(), environment)).status, 404);
    assert.equal((await worker.fetch(request(), environment)).status, 429);
});

test("serves apple-app-site-association for the share links", async () => {
    const response = await worker.fetch(new Request(`${origin}/.well-known/apple-app-site-association`), {});
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Type"), "application/json");
    const body = await response.json();
    assert.deepEqual(body.applinks.details, [{
        appIDs: ["9NXP66M9UL.de.goldkunibert.BetterBahn"],
        components: [{ "/": "/s/*", comment: "Geteilte Reisen" }],
    }]);
    const custom = await worker.fetch(new Request(`${origin}/.well-known/apple-app-site-association`), { APP_IDS: "A.b, C.d" });
    assert.deepEqual((await custom.json()).applinks.details[0].appIDs, ["A.b", "C.d"]);
});

test("other routes are left alone", async () => {
    assert.equal(await handleShare(new Request(`${origin}/datenschutz`), env()), null);
    assert.equal(await handleShare(new Request(`${origin}/sharing`), env()), null);
});

test("random IDs are 8 characters from the base62 alphabet", () => {
    const ids = new Set(Array.from({ length: 1000 }, randomID));
    assert.equal(ids.size, 1000);
    for (const id of ids) assert.match(id, /^[A-Za-z0-9]{8}$/);
});
