import assert from "node:assert/strict";
import test from "node:test";
import worker, { handlePrivacyPolicy, handleTraewellingCallback } from "./worker.mjs";

const endpoint = "https://betterbahn.betterbahn.workers.dev/oauth/traewelling/callback";

test("forwards code and state without changing their values", () => {
    const url = new URL(endpoint);
    url.searchParams.set("code", "code+with/slash=& space");
    url.searchParams.set("state", "state+with/slash=& space");
    url.searchParams.set("redirect_uri", "https://untrusted.example");
    url.searchParams.set("client_secret", "ignored");
    const response = handleTraewellingCallback(new Request(url));
    assert.equal(response.status, 302);
    const callback = new URL(response.headers.get("Location"));
    assert.equal(callback.protocol, "betterbahn:");
    assert.equal(callback.host, "oauth");
    assert.deepEqual([...callback.searchParams], [
        ["code", "code+with/slash=& space"],
        ["state", "state+with/slash=& space"],
    ]);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
});

test("forwards authorization errors with state", () => {
    const response = handleTraewellingCallback(new Request(endpoint + "?error=access_denied&state=abc"));
    assert.equal(response.status, 302);
    const callback = new URL(response.headers.get("Location"));
    assert.equal(callback.searchParams.get("error"), "access_denied");
    assert.equal(callback.searchParams.get("state"), "abc");
});

test("rejects missing, ambiguous, and duplicated parameters", () => {
    for (const query of ["", "?code=abc", "?state=abc", "?code=&state=abc",
        "?code=abc&error=access_denied&state=abc", "?code=abc&code=def&state=abc",
        "?code=abc&state=abc&state=def"]) {
        const response = handleTraewellingCallback(new Request(endpoint + query));
        assert.equal(response.status, 400);
        assert.equal(response.headers.get("Location"), null);
    }
});

test("leaves other routes alone", () => {
    for (const path of ["/.well-known/apple-app-site-association", "/apple-app-site-association", "/"]) {
        assert.equal(handleTraewellingCallback(new Request(new URL(path, endpoint))), null);
    }
});

test("rejects non-GET callbacks", () => {
    const response = handleTraewellingCallback(new Request(endpoint, { method: "POST" }));
    assert.equal(response.status, 405);
    assert.equal(response.headers.get("Allow"), "GET");
});

test("Worker serves the privacy policy, the callback and a 404 fallback", async () => {
    const privacy = await worker.fetch(new Request(new URL("/datenschutz", endpoint)));
    assert.equal(privacy.status, 200);
    assert.equal(privacy.headers.get("Content-Type"), "text/html; charset=utf-8");
    assert.match(await privacy.text(), /keiner Verbindung zur Deutschen Bahn AG/);
    // The association file was never used (the login goes through betterbahn://) and is gone.
    assert.equal((await worker.fetch(new Request(new URL("/.well-known/apple-app-site-association", endpoint)))).status, 404);
    assert.equal((await worker.fetch(new Request(new URL("/unknown", endpoint)))).status, 404);
    assert.equal((await worker.fetch(new Request(endpoint + "?code=test&state=test"))).status, 302);
});

test("privacy policy answers GET and HEAD only", () => {
    assert.equal(handlePrivacyPolicy(new Request(new URL("/datenschutz", endpoint), { method: "POST" })).status, 405);
    assert.equal(handlePrivacyPolicy(new Request(new URL("/datenschutz", endpoint), { method: "HEAD" })).status, 200);
    assert.equal(handlePrivacyPolicy(new Request(endpoint)), null);
});
