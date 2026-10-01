// Proxy for bahn.de's web API. bahn.de's bot protection blocks requests from Apple's URL loading
// stack (403 OPS_BLOCKED) whatever headers the app sends, so the app sends them here instead.
// Paths mirror https://www.bahn.de/web/api/…, so the app only swaps its base URL.
//
// Also forwards DB's Timetables API (`/timetables/v1/…`) with the API key kept here as a secret,
// and hands out the App Attest tokens (`/auth/…`) every request needs (see ../shared/appattest.mjs).

import { handleAuth, isAuthorized, unauthorized } from "../shared/appattest.mjs";

const UPSTREAM = "https://www.bahn.de/web/api/";
const TIMETABLES_UPSTREAM = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1/";

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

// DB Timetables: the hourly schedule and the live changes at a station (EVA number).
const TIMETABLES_ROUTES = [
    { pattern: /^plan\/\d{6,8}\/\d{6}\/\d{2}$/, ttl: 1800 },
    { pattern: /^fchg\/\d{6,8}$/, ttl: 30 },
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

    let upstreamURL, upstreamRequestHeaders;
    if (route.timetables) {
        if (!env.DB_CLIENT_ID || !env.DB_API_KEY) return json(503, { error: "not_configured" });
        upstreamURL = TIMETABLES_UPSTREAM + path;
        upstreamRequestHeaders = { "DB-Client-Id": env.DB_CLIENT_ID, "DB-Api-Key": env.DB_API_KEY, Accept: "application/xml" };
    } else {
        // url.search keeps the query exactly as sent, e.g. "%23" in journey IDs.
        upstreamURL = UPSTREAM + path + url.search;
        upstreamRequestHeaders = upstreamHeaders();
    }
    const cacheKey = new Request(upstreamURL);

    if (cache) {
        const cached = await cache.match(cacheKey);
        if (cached) {
            const hit = new Response(cached.body, cached);
            hit.headers.set("X-Proxy-Cache", "HIT");
            return hit;
        }
    }

    let upstream;
    try {
        upstream = await fetchUpstream(upstreamURL, { headers: upstreamRequestHeaders });
    } catch {
        return json(502, { error: "upstream_unreachable" });
    }

    const body = await upstream.arrayBuffer();
    const headers = {
        "Content-Type": upstream.headers.get("Content-Type") ?? "application/json; charset=utf-8",
        "X-Proxy-Cache": "MISS",
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
    // Pass errors (including 403 OPS_BLOCKED / 429) through unchanged and uncached, so the app's
    // BahnDeGate cooldown still kicks in.
    return new Response(body, { status: upstream.status, headers: { ...headers, "Cache-Control": "no-store" } });
}

export default {
    fetch(request, env, ctx) {
        return handleRequest(request, env, { waitUntil: promise => ctx.waitUntil(promise) });
    },
};
