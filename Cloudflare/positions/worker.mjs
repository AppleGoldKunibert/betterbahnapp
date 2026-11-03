// Live train positions from DB's RIS::Maps (API Marketplace) for the app (`RISMapsClient`): one list of every running
// train of the administrations below, fetched with our API key (kept here as a secret) and cached briefly, so all users
// share one upstream call and the app never says which train it looks at. Only the genuine app may ask (App Attest
// token from betterbahn2, checked with the shared TOKEN_SECRET).

import { isAuthorized, unauthorized } from "../shared/appattest.mjs";

export const UPSTREAM = "https://apis.deutschebahn.com/db/apis/ris-maps/v2/journey-positions/";
// RIS::Maps' client ID for live vehicle positions (the one DB's live map uses).
const APP_ID = "livemap-WebSdk";
const UPSTREAM_TIMEOUT = 8000;
// The Marketplace allows 25,000 calls a day; one call per 15 s and edge location stays well below that.
export const TTL = 15;
// Synthetic key: the upstream call is a POST, which the Cache API can't store.
const CACHE_KEY = "https://positions.betterbahn.internal/journeys";

// RIS administrations (railway undertakings) asked for: DB Fernverkehr ("80") and DB Regio's regional companies and
// S-Bahns. `ADMIN_IDS` (comma-separated, wrangler.toml) replaces the list without a code change.
export const DEFAULT_ADMIN_IDS = [
    "80",
    "800156", "800158", "800165", "800166", "800201", "800292", "800295", "800349", "800352", "800354",
    "800430", "800486", "800489", "800528", "800643", "800654", "800721", "800725", "800759", "800765",
    "801518", "801539", "8003G2", "8003L1", "8004A9", "8004L1", "8004NT", "8005KG", "8005MW", "8007D5",
];

export function adminIds(env = {}) {
    const ids = (env.ADMIN_IDS ?? "").split(",").map(id => id.trim()).filter(Boolean);
    return ids.length ? ids : DEFAULT_ADMIN_IDS;
}

function json(status, body, extra = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
    });
}

const finite = value => (typeof value === "number" && Number.isFinite(value) ? value : undefined);

/// RIS::Maps' `positions` in the app's compact form; entries without a position or journey ID are dropped.
export function compact(positions, fetchedAt) {
    const trains = [];
    for (const position of Array.isArray(positions) ? positions : []) {
        const lat = finite(position?.latitude), lon = finite(position?.longitude);
        if (lat === undefined || lon === undefined || typeof position.journeyID !== "string") continue;
        const transport = position.info?.transportAtStart ?? {};
        const train = {
            id: position.journeyID,
            category: transport.category,
            number: Number.isInteger(transport.journeyNumber) ? transport.journeyNumber : undefined,
            name: transport.journeyName,
            line: transport.line,
            destination: position.info?.destination?.name,
            lat,
            lon,
            speed: finite(position.speed),
            time: position.meta?.timeInformation,
            source: position.metaSource,
        };
        trains.push(Object.fromEntries(Object.entries(train).filter(([, value]) => value !== undefined && value !== "")));
    }
    return { fetchedAt: new Date(fetchedAt).toISOString(), trains };
}

/// Asks RIS::Maps; returns `{ status, positions }` (positions only on success) or null when unreachable.
export async function fetchPositions(env, fetchUpstream) {
    try {
        const response = await fetchUpstream(UPSTREAM, {
            method: "POST",
            headers: {
                "DB-Client-Id": env.DB_CLIENT_ID,
                "DB-Api-Key": env.DB_API_KEY,
                "RISMAPS-App-Id": APP_ID,
                Accept: "application/vnd.de.db.ris+json",
                "Content-Type": "application/json",
            },
            body: JSON.stringify({ administrationIDs: adminIds(env) }),
            signal: AbortSignal.timeout(UPSTREAM_TIMEOUT),
        });
        if (!response.ok) return { status: response.status };
        const body = await response.json();
        return Array.isArray(body?.positions) ? { status: 200, positions: body.positions } : { status: 502 };
    } catch {
        return null;
    }
}

// `deps` lets tests replace fetch, the edge cache and the clock.
export async function handleRequest(request, env = {}, deps = {}) {
    const fetchUpstream = deps.fetch ?? fetch;
    const cache = deps.cache ?? (typeof caches === "undefined" ? null : caches.default);
    const now = deps.now ?? Date.now;
    const url = new URL(request.url);

    if (url.pathname === "/health") return json(200, { ok: true });
    if (url.pathname !== "/journeys") return json(404, { error: "not_found" });
    if (request.method !== "GET") return json(405, { error: "method_not_allowed" }, { Allow: "GET" });

    // Always the genuine app only: every upstream call spends our API key.
    if (!(await isAuthorized(request, env, { required: true }))) return unauthorized();
    if (!env.DB_CLIENT_ID || !env.DB_API_KEY) return json(503, { error: "not_configured" });

    const cacheKey = new Request(CACHE_KEY);
    const cached = cache ? await cache.match(cacheKey) : null;
    if (cached) {
        const hit = new Response(cached.body, cached);
        hit.headers.set("X-Proxy-Cache", "HIT");
        return hit;
    }

    const result = await fetchPositions(env, fetchUpstream);
    if (!result) return json(502, { error: "upstream_unreachable" });
    // 429 is passed on so the app pauses; other upstream errors read as "not reachable" (the app falls back).
    if (!result.positions) return json(result.status === 429 ? 429 : 502, { error: "upstream_error", status: result.status });

    const response = json(200, compact(result.positions, now()), {
        "Cache-Control": `public, max-age=${TTL}`,
        "X-Proxy-Cache": "MISS",
    });
    if (cache) {
        const store = cache.put(cacheKey, response.clone());
        deps.waitUntil ? deps.waitUntil(store) : await store;
    }
    return response;
}

export default {
    fetch(request, env, ctx) {
        return handleRequest(request, env, { waitUntil: promise => ctx.waitUntil(promise) });
    },
};
