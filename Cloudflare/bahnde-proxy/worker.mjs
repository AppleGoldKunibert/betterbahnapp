// Forwards DB's OpenBoards API (`/openboards/v1/…`, the successor of Timetables), DB's Timetables API
// (`/timetables/v1/…`, kept for app builds that still ask it until DB switches it off) and the lifts out of
// order from DB's FaSta API (`/fasta/v2/facilities`, #486) with the API key kept here as a secret, and hands out the App Attest
// tokens (`/auth/…`) every request to our servers needs (see ../shared/appattest.mjs).
// bahn.de itself refuses Workers since October 2026; the app asks it through Server/bahnde-proxy.

import { handleAuth, isAuthorized, unauthorized } from "../shared/appattest.mjs";

const TIMETABLES_UPSTREAM = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1/";
// The same IRIS service that sits behind Timetables, as DB's own departure board uses it: no key and no
// 60 calls/minute limit. DB marked it deprecated (it may be switched off), so Timetables stays as the fallback.
const IRIS_UPSTREAM = "https://iris.noncd.db.de/iris-tts/timetable/";
const TIMETABLES_TIMEOUT = 8000;
// IRIS answers these for "no such data" (as bahn.expert treats them): Timetables would say the same, so no fallback.
const NO_DATA_STATUSES = new Set([400, 404, 410]);

// DB Timetables: the hourly schedule and the live changes at a station (EVA number), and the
// station itself, whose `meta` lists the EVAs of its other levels (e.g. "Hamburg Hbf (S-Bahn)").
const TIMETABLES_ROUTES = [
    { pattern: /^plan\/\d{6,8}\/\d{6}\/\d{2}$/, ttl: 1800 },
    { pattern: /^fchg\/\d{6,8}$/, ttl: 30 },
    { pattern: /^station\/\d{6,8}$/, ttl: 86400 },
];

// DB OpenBoards: the departure and arrival boards of a station, live times and platforms included. The app asks
// with GET (`?evas=8000105,8098105&from=…&to=…`, times in ISO 8601 UTC) and this Worker builds the POST body, so
// nobody can spend our API key on any other request.
const OPENBOARDS_UPSTREAM = "https://apis.deutschebahn.com/db-api-marketplace/apis/open-boards/v1/";
const OPENBOARDS_PATHS = { "/openboards/v1/departures": "departures", "/openboards/v1/arrivals": "arrivals" };
const OPENBOARDS_TTL = 30;
const OPENBOARDS_MAX_WINDOW = 8 * 3600 * 1000; // DB's own limit
const OPENBOARDS_MAX_EVAS = 5;

// DB FaSta (Facility Status): every station lift in Germany that is out of order, one list for all users, so the
// app never says which station it looks at. Lifts are only polled every few minutes upstream anyway.
const FASTA_UPSTREAM = "https://apis.deutschebahn.com/db-api-marketplace/apis/fasta/v2/";
const FASTA_PATH = "facilities?type=ELEVATOR&state=INACTIVE";
const FASTA_TTL = 300;

/// The allowed route for `pathname` (`path` relative to its upstream, cache TTL in seconds), or null.
export function matchRoute(pathname) {
    if (pathname.startsWith("/timetables/v1/")) {
        const path = pathname.slice("/timetables/v1/".length);
        const ttl = TIMETABLES_ROUTES.find(route => route.pattern.test(path))?.ttl;
        return ttl === undefined ? null : { path, ttl };
    }
    if (OPENBOARDS_PATHS[pathname]) return { openboards: OPENBOARDS_PATHS[pathname] };
    if (pathname === "/fasta/v2/facilities") return { path: FASTA_PATH, ttl: FASTA_TTL, fasta: true };
    return null;
}

async function upstreamAnswer(url, headers, fetchUpstream, init = {}) {
    try {
        const response = await fetchUpstream(url, { headers, signal: AbortSignal.timeout(TIMETABLES_TIMEOUT), ...init });
        return { response, body: await response.arrayBuffer() };
    } catch {
        return { response: null, body: null };
    }
}

/// DB Timetables: the keyless IRIS first, the API Marketplace (with our key, 60 calls/minute) only when IRIS fails
/// (error, timeout, 5xx, 429 …). Returns `{ upstream, body }` where `upstream` is the successful response or the
/// error to pass on (the Marketplace's if both failed), or null if nothing was reachable.
export async function fetchTimetables(path, env, fetchUpstream) {
    const iris = await upstreamAnswer(IRIS_UPSTREAM + path, { Accept: "application/xml" }, fetchUpstream);
    if (iris.response && (iris.response.ok || NO_DATA_STATUSES.has(iris.response.status))) {
        return { upstream: iris.response, body: iris.body };
    }
    if (env.DB_CLIENT_ID && env.DB_API_KEY) {
        const marketplace = await upstreamAnswer(TIMETABLES_UPSTREAM + path,
            { "DB-Client-Id": env.DB_CLIENT_ID, "DB-Api-Key": env.DB_API_KEY, Accept: "application/xml" }, fetchUpstream);
        if (marketplace.response) return { upstream: marketplace.response, body: marketplace.body };
    }
    return iris.response ? { upstream: iris.response, body: iris.body } : null;
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

    // Only the genuine app (App Attest token), always: Timetables and FaSta spend our API key.
    if (!(await isAuthorized(request, env, { required: true }))) return unauthorized();

    if (route.fasta) return fastaResponse(env, fetchUpstream, cache, deps);
    if (route.openboards) return openBoardsResponse(route.openboards, url.searchParams, env, fetchUpstream, cache, deps);
    return timetablesResponse(path, ttl, env, fetchUpstream, cache, deps);
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
    return await answer(result.upstream, result.body, ttl, cacheKey, cache, deps);
}

const ISO_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

/// The board's validated query: station EVAs and the time window as UTC ISO strings, or null for anything else.
export function openBoardsQuery(params) {
    const evas = (params.get("evas") ?? "").split(",");
    if (evas.length > OPENBOARDS_MAX_EVAS || !evas.every(eva => /^\d{6,8}$/.test(eva))) return null;
    // A "+" offset arrives as a space (URL decoding).
    const [from, to] = ["from", "to"].map(name => (params.get(name) ?? "").replace(" ", "+"));
    if (!ISO_TIME.test(from) || !ISO_TIME.test(to)) return null;
    const start = Date.parse(from);
    const end = Date.parse(to);
    if (!(end > start) || end - start > OPENBOARDS_MAX_WINDOW) return null;
    return { evas, timeStart: new Date(start).toISOString(), timeEnd: new Date(end).toISOString() };
}

async function openBoardsResponse(board, params, env, fetchUpstream, cache, deps) {
    const query = openBoardsQuery(params);
    if (!query) return json(400, { error: "bad_request" });
    if (!env.DB_CLIENT_ID || !env.DB_API_KEY) return json(503, { error: "not_configured" });
    const { evas, timeStart, timeEnd } = query;
    // The cache key is the normalized request, so the same board asked in other spellings is one entry.
    const cacheKey = new Request(`${OPENBOARDS_UPSTREAM}${board}?evas=${evas.join(",")}&from=${timeStart}&to=${timeEnd}`);
    const cached = await cachedAnswer(cache, cacheKey);
    if (cached) return cached;

    const headers = {
        "DB-Client-Id": env.DB_CLIENT_ID, "DB-Api-Key": env.DB_API_KEY,
        "Content-Type": "application/json", Accept: "application/json",
    };
    const body = JSON.stringify({
        stopPlaceOrStation: { evaNumbers: evas },
        timeWindow: { timeStart, timeEnd },
        maxEntriesPerTransportType: 50,
        languages: ["deu"],
    });
    const result = await upstreamAnswer(OPENBOARDS_UPSTREAM + board, headers, fetchUpstream, { method: "POST", body });
    if (!result.response) return json(502, { error: "upstream_unreachable" });
    return await answer(result.response, result.body, OPENBOARDS_TTL, cacheKey, cache, deps);
}

async function fastaResponse(env, fetchUpstream, cache, deps) {
    if (!env.DB_CLIENT_ID || !env.DB_API_KEY) return json(503, { error: "not_configured" });
    const url = FASTA_UPSTREAM + FASTA_PATH;
    const cacheKey = new Request(url);
    const cached = await cachedAnswer(cache, cacheKey);
    if (cached) return cached;

    const headers = { "DB-Client-Id": env.DB_CLIENT_ID, "DB-Api-Key": env.DB_API_KEY, Accept: "application/json" };
    const result = await upstreamAnswer(url, headers, fetchUpstream);
    if (!result.response) return json(502, { error: "upstream_unreachable" });
    return await answer(result.response, result.body, FASTA_TTL, cacheKey, cache, deps);
}

// A successful upstream answer is cached for `ttl`; errors (including 429) pass through unchanged and uncached.
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
