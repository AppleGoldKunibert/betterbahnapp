// Worker `betterbahn-stats`: answers the app with train statistics (#316): per train number and stop, how
// late the train was in the last 30 days, how often it was cancelled and which platforms it used.
//
// The data comes from piebro/deutsche-bahn-data (DB Timetables of every German station, CC BY 4.0, source
// Deutsche Bahn), imported once a day by `importer.py` (GitHub Action `train-stats-import.yml`) into D1, one
// row per train number and day (schema.sql). The Worker itself asks nobody: no bahn.de requests (#336).

import { TOKEN_HEADER, unauthorized, verifyToken } from "../shared/appattest.mjs";

// MARK: - HTTP

export async function handleRequest(request, env = {}, now = Date.now()) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json(200, { ok: true });
    if (url.pathname !== "/train-stats") return json(404, { error: "not_found" });
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" }, { Allow: "POST" });
    if (!env.DB) return json(503, { error: "not_configured" });

    const refused = await refuse(request, env, now, env.STATS_LIMITER);
    if (refused) return refused;
    return handleTrainStats(request, env, now);
}

/// Only the genuine app: an App Attest token from the bahn.de proxy (same TOKEN_SECRET), or no token
/// while ALLOW_UNATTESTED is "true" (see ../shared/appattest.mjs). A response when the request is
/// refused (unauthorised, rate limited), otherwise null.
async function refuse(request, env, now, limiter) {
    const token = request.headers.get(TOKEN_HEADER);
    const claims = token && env.TOKEN_SECRET ? await verifyToken(token, "a", env.TOKEN_SECRET, now) : null;
    if (token ? !claims : env.ALLOW_UNATTESTED !== "true") return unauthorized();
    if (limiter) {
        const key = claims?.kid ?? request.headers.get("CF-Connecting-IP") ?? "unknown";
        const { success } = await limiter.limit({ key: String(key) });
        if (!success) return json(429, { error: "rate_limited" });
    }
    return null;
}

function json(status, body, extra = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
    });
}

// MARK: - Train statistics

export const MAX_TRAINS = 8;
const MAX_STOPS_PER_TRAIN = 12;
const EVA_PATTERN = /^\d{1,9}$/;
const TRAIN_PATTERN = /^[A-Za-z0-9]{1,8}$/;
// The last days that count.
const DEFAULT_DAYS = 30;
// Long-distance categories, which DB and the app name alike. Everything else is regional: DB stores many
// regional trains under their operator's category ("HLB", "ag", "erx"), the app knows them as "RE 5" or
// "RB 27", so those match by run number and stop instead.
const LONG_DISTANCE = new Set(["ICE", "IC", "EC", "ECE", "EN", "NJ", "RJ", "RJX", "TGV", "FLX", "IR", "D", "EUR", "ES", "EST", "THA", "ICD", "UEX", "WB"]);

// Big stations whose lower levels DB Timetables lists as stations of their own: importer.py keeps their stops
// under the main station (same list there), so a stop asked for by its lower level is looked up there too.
const LOWER_LEVELS = { 8098263: "8000261", 8098096: "8000096", 8098105: "8000105", 8098549: "8002549", 8098205: "8010205", 8098160: "8011160", 8089021: "8011160" };

async function handleTrainStats(request, env, now) {
    let trains;
    try {
        trains = (await request.json())?.trains;
    } catch {
        return json(400, { error: "invalid_json" });
    }
    if (!Array.isArray(trains) || trains.length > MAX_TRAINS) return json(400, { error: "invalid_trains" });
    const queries = [];
    for (const train of trains) {
        const evas = Array.isArray(train?.evas) ? train.evas : [];
        if (!TRAIN_PATTERN.test(train?.category ?? "") || !TRAIN_PATTERN.test(String(train?.number ?? ""))
            || evas.length > MAX_STOPS_PER_TRAIN || !evas.every(eva => EVA_PATTERN.test(String(eva)))) {
            return json(400, { error: "invalid_trains" });
        }
        queries.push({ category: train.category.toUpperCase(), number: String(train.number), evas: evas.map(String) });
    }

    const days = Number(env.STATS_DAYS) > 0 ? Number(env.STATS_DAYS) : DEFAULT_DAYS;
    const since = new Date(now - days * 86400_000).toISOString().slice(0, 10);
    const select = env.DB.prepare("SELECT runs FROM train_days WHERE number = ? AND day >= ?");
    const answers = await Promise.all(queries.map(async query => {
        const { results } = await select.bind(query.number, since).all();
        const runs = (results ?? []).flatMap(row => parseJSON(row.runs) ?? []);
        return trainStatistics(runs, query, days);
    }));
    return json(200, { trains: answers });
}

/// What the `runs` of one train number say about the train asked for, and about its stops `query.evas`:
/// - `runs`/`cancelled`: its runs, and those cancelled altogether;
/// - per stop: runs that had the stop, how many cancelled it, the arrival and departure delays in
///   minutes (cancelled stops have none) and the platform moves `{ from: planned, to: actual, n }`.
/// `runs` as stored in `train_days.runs`: `{ c: category, x: 1 when cancelled, s: stops }` (schema.sql).
export function trainStatistics(runs, query, days = DEFAULT_DAYS) {
    const parsed = runs
        .map(run => ({ category: String(run?.c ?? "").toUpperCase(), cancelled: run?.x === 1, stops: Array.isArray(run?.s) ? run.s : [] }))
        .filter(run => isTrain(run, query));
    const stops = {};
    for (const eva of query.evas) {
        const stop = stopStatistics(parsed, LOWER_LEVELS[eva] ?? eva);
        if (stop.runs > 0) stops[eva] = stop;
    }
    return {
        category: query.category,
        number: query.number,
        days,
        runs: parsed.length,
        cancelled: parsed.filter(run => run.cancelled).length,
        stops,
    };
}

/// Whether `run` is the train asked for: the same category, or both regional and calling at one of the
/// stops asked for (a number alone is not unique across the regional operators).
function isTrain(run, query) {
    if (run.category === query.category) return true;
    return !LONG_DISTANCE.has(run.category) && !LONG_DISTANCE.has(query.category)
        && run.stops.some(row => query.evas.some(eva => (LOWER_LEVELS[eva] ?? eva) === row[0]));
}

function stopStatistics(runs, eva) {
    const stop = { runs: 0, cancelled: 0, arrival: [], departure: [], platforms: [] };
    const moves = new Map();
    for (const run of runs) {
        // [eva, arrivalDelay, departureDelay, platform, changedPlatform, flags] (see schema.sql)
        const row = run.stops.find(candidate => candidate[0] === eva);
        if (!row) continue;
        stop.runs++;
        if (run.cancelled || (row[5] ?? 0) & 1) {
            stop.cancelled++;
            continue;
        }
        if (Number.isInteger(row[1])) stop.arrival.push(row[1]);
        if (Number.isInteger(row[2])) stop.departure.push(row[2]);
        if (row[3]) {
            const to = row[4] ?? row[3];
            const move = moves.get(`${row[3]}\t${to}`) ?? { from: row[3], to, n: 0 };
            move.n++;
            moves.set(`${row[3]}\t${to}`, move);
        }
    }
    stop.platforms = [...moves.values()].sort((a, b) => b.n - a.n);
    return stop;
}

function parseJSON(text) {
    try {
        return text ? JSON.parse(text) : null;
    } catch {
        return null;
    }
}

export default {
    fetch(request, env) {
        return handleRequest(request, env);
    },
};
