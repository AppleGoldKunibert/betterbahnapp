// Proxy for bahn.de's web API. bahn.de's bot protection blocks requests from Apple's URL loading
// stack (403 OPS_BLOCKED) whatever headers the app sends, so the app sends them here instead.
// Paths mirror https://www.bahn.de/web/api/…, so the app only swaps its base URL.
//
// Also forwards DB's Timetables API (`/timetables/v1/…`) with the API key kept here as a secret,
// and hands out the App Attest tokens (`/auth/…`) every request needs (see ../shared/appattest.mjs).

import { handleAuth, isAuthorized, unauthorized } from "../shared/appattest.mjs";

const UPSTREAM = "https://www.bahn.de/web/api/";
const TIMETABLES_UPSTREAM = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1/";
// The same IRIS service that sits behind Timetables, as DB's own departure board uses it: no key and no
// 60 calls/minute limit. DB marked it deprecated (it may be switched off), so Timetables stays as the fallback.
const IRIS_UPSTREAM = "https://iris.noncd.db.de/iris-tts/timetable/";
const TIMETABLES_TIMEOUT = 8000;
// IRIS answers these for "no such data" (as bahn.expert treats them): Timetables would say the same, so no fallback.
const NO_DATA_STATUSES = new Set([400, 404, 410]);

// Allowed paths (relative to /web/api/) and how long a successful answer is cached, in seconds.
// Short TTLs keep realtime data fresh while collapsing repeated app requests into one DB request.
export const ROUTES = {
    "reiseloesung/orte": 86400,
    "reiseloesung/orte/nearby": 86400,
    "reiseloesung/abfahrten": 30,
    "reiseloesung/ankuenfte": 30,
    "reiseloesung/fahrt": 30,
    "reisebegleitung/wagenreihung/vehicle-sequence": 120,
};

// bahn.de paths with an ID in them; the pattern checks the ID, so nothing else gets through.
const PATTERN_ROUTES = [
    // A connection shared from the DB Navigator or bahn.de (the "Verbindung ansehen" link's vbid).
    { pattern: /^angebote\/verbindung\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, ttl: 3600 },
];

// DB Timetables: the hourly schedule and the live changes at a station (EVA number), and the
// station itself, whose `meta` lists the EVAs of its other levels (e.g. "Hamburg Hbf (S-Bahn)").
const TIMETABLES_ROUTES = [
    { pattern: /^plan\/\d{6,8}\/\d{6}\/\d{2}$/, ttl: 1800 },
    { pattern: /^fchg\/\d{6,8}$/, ttl: 30 },
    { pattern: /^station\/\d{6,8}$/, ttl: 86400 },
];

/// The allowed route for `pathname` (`path` relative to its upstream, cache TTL in seconds), or null.
export function matchRoute(pathname) {
    if (pathname.startsWith("/web/api/")) {
        const path = pathname.slice("/web/api/".length);
        const ttl = Object.hasOwn(ROUTES, path) ? ROUTES[path] : PATTERN_ROUTES.find(route => route.pattern.test(path))?.ttl;
        return ttl === undefined ? null : { path, ttl, timetables: false };
    }
    if (pathname.startsWith("/timetables/v1/")) {
        const path = pathname.slice("/timetables/v1/".length);
        const ttl = TIMETABLES_ROUTES.find(route => route.pattern.test(path))?.ttl;
        return ttl === undefined ? null : { path, ttl, timetables: true };
    }
    return null;
}

// Browser agents Travel::Status::DE::DBRIS sends (same list as BahnDeClient.browserUserAgents).
const USER_AGENTS = [
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.XXXX.YYY Mobile Safari/537.36",
    "Mozilla/5.0 (Linux; Android 14; SM-S928B/DS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.XXXX.YYY Mobile Safari/537.36",
    "Mozilla/5.0 (Linux; Android 14; Pixel 9 Pro Build/AD1A.240418.003; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.XXXX.YYY Mobile Safari/537.36",
    "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.XXXX.YYY Mobile Safari/537.36",
    "Mozilla/5.0 (Linux; Android 15; moto g - 2025 Build/V1VK35.22-13-2; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/132.0.XXXX.YYY Mobile Safari/537.36",
    "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.XXXX.YYY Safari/537.36",
];

const randomInt = max => Math.floor(Math.random() * max);

export function upstreamHeaders() {
    const agent = USER_AGENTS[randomInt(USER_AGENTS.length)]
        .replace("XXXX", String(randomInt(1000)))
        .replace("YYY", String(randomInt(100)));
    return {
        "Accept": "application/json",
        "Content-Type": "application/json; charset=utf-8",
        "Origin": "https://www.bahn.de",
        "Referer": "https://www.bahn.de/buchung/fahrplan/suche",
        "User-Agent": agent,
        "x-correlation-id": `${crypto.randomUUID()}_${crypto.randomUUID()}`,
    };
}

// DIAGNOSTICS (remove later): what decides whether two Timetables answers say the same thing: the stops (`s`)
// and their planned/changed times, platforms, status and path. Message timestamps and formatting don't count.
const COMPARED_ATTRIBUTES = new Set(["id", "eva", "name", "pt", "ct", "pp", "cp", "ps", "cs", "l", "ppth", "cpth"]);

export function timetablesFingerprint(xml) {
    const parts = [];
    for (const [, tag, attributes] of xml.matchAll(/<(station|s|ar|dp)\b([^>]*)>/g)) {
        const kept = [...attributes.matchAll(/([\w-]+)="([^"]*)"/g)]
            .filter(([, name]) => COMPARED_ATTRIBUTES.has(name))
            .map(([, name, value]) => `${name}=${value}`)
            .sort();
        parts.push(`${tag} ${kept.join(" ")}`);
    }
    return parts.join("\n");
}

async function timetablesAnswer(url, headers, fetchUpstream) {
    const started = Date.now();
    try {
        const response = await fetchUpstream(url, { headers, signal: AbortSignal.timeout(TIMETABLES_TIMEOUT) });
        return { response, body: await response.arrayBuffer(), ms: Date.now() - started };
    } catch {
        return { response: null, body: null, ms: Date.now() - started };
    }
}

const describe = answer => answer ? `${answer.response?.status ?? "error"}/${answer.ms}ms` : "skipped";

/// DB Timetables: the keyless IRIS first, the API Marketplace (with our key, 60 calls/minute) only when IRIS fails
/// (error, timeout, 5xx, 429 …). Returns `{ upstream, body, source }` where `upstream` is the successful response or
/// the error to pass on (the Marketplace's if both failed), or null if nothing was reachable.
/// DIAGNOSTICS (remove later): `diagnostics` says what each source answered. With `TIMETABLES_DIAGNOSE=compare`
/// the Marketplace is asked as well, even when IRIS answered, and `same` tells whether both say the same.
export async function fetchTimetables(path, env, fetchUpstream) {
    const hasKey = Boolean(env.DB_CLIENT_ID && env.DB_API_KEY);
    const askMarketplace = () => timetablesAnswer(TIMETABLES_UPSTREAM + path,
        { "DB-Client-Id": env.DB_CLIENT_ID, "DB-Api-Key": env.DB_API_KEY, Accept: "application/xml" }, fetchUpstream);

    const iris = await timetablesAnswer(IRIS_UPSTREAM + path, { Accept: "application/xml" }, fetchUpstream);
    const irisUsable = iris.response && (iris.response.ok || NO_DATA_STATUSES.has(iris.response.status));
    const compare = irisUsable && hasKey && env.TIMETABLES_DIAGNOSE === "compare";
    const marketplace = !irisUsable && hasKey || compare ? await askMarketplace() : null;

    let same = "-";
    if (compare && iris.response.ok && marketplace.response?.ok) {
        const text = answer => new TextDecoder().decode(answer.body);
        same = timetablesFingerprint(text(iris)) === timetablesFingerprint(text(marketplace)) ? "yes" : "NO";
    }
    const diagnostics = `iris=${describe(iris)}; marketplace=${describe(marketplace)}; same=${same}`;

    if (irisUsable) return { ...iris, upstream: iris.response, source: "iris", diagnostics };
    if (marketplace?.response) {
        return { ...marketplace, upstream: marketplace.response, source: marketplace.response.ok ? "marketplace" : "failed", diagnostics };
    }
    if (iris.response) return { ...iris, upstream: iris.response, source: "failed", diagnostics };
    return null;
}

function json(status, body, extra = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
    });
}

// `deps` lets tests replace fetch and the edge cache.
export async function handleRequest(request, env = {}, deps = {}) {
    const fetchUpstream = deps.fetch ?? fetch;
    const cache = deps.cache ?? (typeof caches === "undefined" ? null : caches.default);
    const url = new URL(request.url);

    if (url.pathname === "/health") return json(200, { ok: true });

    const auth = await handleAuth(request, env);
    if (auth) return auth;

    const route = matchRoute(url.pathname);
    if (!route) return json(404, { error: "not_found" });
    const { path, ttl } = route;

    if (request.method !== "GET") return json(405, { error: "method_not_allowed" }, { Allow: "GET" });

    // Only the genuine app (App Attest token). Timetables always needs one: it spends our API key.
    if (!(await isAuthorized(request, env, { required: route.timetables }))) return unauthorized();

    if (route.timetables) return timetablesResponse(path, ttl, env, fetchUpstream, cache, deps);

    // url.search keeps the query exactly as sent, e.g. "%23" in journey IDs.
    const upstreamURL = UPSTREAM + path + url.search;
    const cacheKey = new Request(upstreamURL);

    const cached = await cachedAnswer(cache, cacheKey);
    if (cached) return cached;

    let upstream;
    try {
        upstream = await fetchUpstream(upstreamURL, { headers: upstreamHeaders() });
    } catch {
        return json(502, { error: "upstream_unreachable" });
    }
    return await answer(upstream, await upstream.arrayBuffer(), ttl, cacheKey, cache, deps);
}

async function cachedAnswer(cache, cacheKey) {
    const cached = cache ? await cache.match(cacheKey) : null;
    if (!cached) return null;
    const hit = new Response(cached.body, cached);
    hit.headers.set("X-Proxy-Cache", "HIT");
    return hit;
}

async function timetablesResponse(path, ttl, env, fetchUpstream, cache, deps) {
    // Cached under the Marketplace URL as before, whichever source answered.
    const cacheKey = new Request(TIMETABLES_UPSTREAM + path);
    const cached = await cachedAnswer(cache, cacheKey);
    if (cached) return cached;

    const result = await fetchTimetables(path, env, fetchUpstream);
    if (!result) return json(502, { error: "upstream_unreachable" });
    // DIAGNOSTICS (remove later): visible with `wrangler tail` and in the X-Timetables-* response headers.
    console.log(`timetables ${path} source=${result.source} ${result.diagnostics}`);
    return await answer(result.upstream, result.body, ttl, cacheKey, cache, deps,
        { "X-Timetables-Source": result.source, "X-Timetables-Diag": result.diagnostics });
}

// A successful upstream answer is cached for `ttl`; errors (including 403 OPS_BLOCKED / 429) pass
// through unchanged and uncached, so the app's BahnDeGate cooldown still kicks in.
async function answer(upstream, body, ttl, cacheKey, cache, deps, extra = {}) {
    const headers = {
        "Content-Type": upstream.headers.get("Content-Type") ?? "application/json; charset=utf-8",
        "X-Proxy-Cache": "MISS",
        ...extra,
    };
    if (upstream.ok) {
        const response = new Response(body, {
            status: upstream.status,
            headers: { ...headers, "Cache-Control": `public, max-age=${ttl}` },
        });
        if (cache) {
            const store = cache.put(cacheKey, response.clone());
            deps.waitUntil ? deps.waitUntil(store) : await store;
        }
        return response;
    }
    return new Response(body, { status: upstream.status, headers: { ...headers, "Cache-Control": "no-store" } });
}

export default {
    fetch(request, env, ctx) {
        return handleRequest(request, env, { waitUntil: promise => ctx.waitUntil(promise) });
    },
};
