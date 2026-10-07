// Worker `betterbahn-stats`: collects realtime data for statistics (#169) – delays, platform changes,
// cancellations, disruption reasons and the vehicles used – for every regional and long-distance train
// an app user has seen, until it reaches its terminus.
//
// The app reports the bahn.de journey IDs of trains it showed (`POST /sightings`); no user ID, no
// location. A cron trigger then asks bahn.de about each run itself: its schedule right away, its
// Wagenreihung around departure and its final realtime state after arrival, stored in D1 (schema.sql).
// Runs older than a year are downloaded and deleted with backup.sh.

import { TOKEN_HEADER, unauthorized, verifyToken } from "../shared/appattest.mjs";
import { upstreamHeaders } from "../bahnde-proxy/worker.mjs";

const UPSTREAM = "https://www.bahn.de/web/api/";

export const MAX_SIGHTINGS = 100;
const MAX_JOURNEY_ID_LENGTH = 500;
// bahn.de's journey IDs: "2|#VN#1#ST#…#ZE#1095#ZB#ICE  1095#…". Printable ASCII and umlauts only.
const JOURNEY_ID_PATTERN = /^\d+\|#[\x20-\x7eÀ-ſ]+$/;

// Trains we don't keep: S-Bahn, and anything that isn't a train. Categories as in bahn.de's IDs.
const EXCLUDED_CATEGORIES = new Set(["S", "SBAHN", "U", "STR", "TRAM", "BUS", "BSV", "RUF", "ALT", "AST", "TAXI", "FAE", "SCHIFF", "SEV"]);

// How many runs one cron invocation handles. Each costs one bahn.de request; the free plan allows
// 50 outgoing requests and 10 ms CPU per invocation.
const DEFAULT_BATCH = 8;
const MINUTE = 60;
const MAX_ATTEMPTS = 5;
// The final look happens this long after the planned (or, when late, the expected) arrival, so the
// last realtime update is in; a train still running then is looked at again later, up to 12 hours on.
const AFTER_ARRIVAL = 30 * MINUTE;
const GIVE_UP_AFTER = 12 * 3600;

// MARK: - HTTP

export async function handleRequest(request, env = {}, now = Date.now()) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json(200, { ok: true });
    if (url.pathname !== "/sightings") return json(404, { error: "not_found" });
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" }, { Allow: "POST" });
    if (!env.DB) return json(503, { error: "not_configured" });

    // Only the genuine app: an App Attest token from the bahn.de proxy (same TOKEN_SECRET), or no
    // token while ALLOW_UNATTESTED is "true" (see ../shared/appattest.mjs).
    const token = request.headers.get(TOKEN_HEADER);
    const claims = token && env.TOKEN_SECRET ? await verifyToken(token, "a", env.TOKEN_SECRET, now) : null;
    if (token ? !claims : env.ALLOW_UNATTESTED !== "true") return unauthorized();
    if (env.SIGHTINGS_LIMITER) {
        const key = claims?.kid ?? request.headers.get("CF-Connecting-IP") ?? "unknown";
        const { success } = await env.SIGHTINGS_LIMITER.limit({ key: String(key) });
        if (!success) return json(429, { error: "rate_limited" });
    }

    let ids;
    try {
        ids = (await request.json())?.journeyIds;
    } catch {
        return json(400, { error: "invalid_json" });
    }
    if (!Array.isArray(ids) || ids.length > MAX_SIGHTINGS) return json(400, { error: "invalid_sightings" });

    const runs = new Map();
    for (const id of ids) {
        if (!isJourneyId(id)) continue;
        const fields = journeyFields(id);
        if (fields.CA && EXCLUDED_CATEGORIES.has(fields.CA.toUpperCase())) continue;
        runs.set(runKey(id), id);
    }
    if (runs.size > 0) {
        const seconds = Math.floor(now / 1000);
        // A run seen before is ignored; ignored inserts write nothing.
        const insert = env.DB.prepare("INSERT OR IGNORE INTO runs (key, journey_id, state, next_check, first_seen) VALUES (?, ?, 'new', ?, ?)");
        await env.DB.batch([...runs].map(([key, id]) => insert.bind(key, id, seconds, seconds)));
    }
    return json(202, { accepted: runs.size });
}

export function isJourneyId(id) {
    return typeof id === "string" && id.length <= MAX_JOURNEY_ID_LENGTH && JOURNEY_ID_PATTERN.test(id);
}

/// The "#XX#value" fields of a bahn.de journey ID, e.g. { ZE: "1095", CA: "ICE", DA: "61026", "1S": "8000261" }.
export function journeyFields(id) {
    const fields = {};
    const parts = id.slice(id.indexOf("|") + 1).split("#");
    // ["", "VN", "1", "ST", "…", …]: names and values alternate after the leading "#".
    for (let i = 1; i + 1 < parts.length; i += 2) fields[parts[i]] = parts[i + 1].trim();
    return fields;
}

/// One key per run, whichever board or search the ID came from (their IDs can differ in search details).
export function runKey(id) {
    const f = journeyFields(id);
    return f.DA && f.CA && f.ZE && f["1S"] ? `${f.DA}|${f.CA}|${f.ZE}|${f["1S"]}` : id;
}

function json(status, body, extra = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
    });
}

// MARK: - Cron

/// Looks at the runs that are due: oldest first, at most `BATCH` (env) per invocation.
export async function processDueRuns(env, now = Date.now(), deps = {}) {
    const fetchUpstream = deps.fetch ?? fetch;
    const seconds = Math.floor(now / 1000);
    const batch = Number(env.BATCH) > 0 ? Number(env.BATCH) : DEFAULT_BATCH;
    const { results } = await env.DB.prepare(
        "SELECT key, journey_id, state, attempts, first_seen, service_day, category, number, origin_eva, planned_departure, planned_arrival " +
        "FROM runs WHERE state IN ('new', 'planned', 'formed') AND next_check <= ? ORDER BY next_check LIMIT ?",
    ).bind(seconds, batch).all();

    const statements = [];
    for (const run of results ?? []) {
        let update;
        try {
            update = await step(run, seconds, fetchUpstream);
        } catch {
            update = retry(run, seconds);
        }
        statements.push(...[update(env.DB)].flat());
    }
    if (statements.length > 0) await env.DB.batch(statements);
    return results?.length ?? 0;
}

/// What to do with `run` now; returns a function building its D1 statement.
async function step(run, now, fetchUpstream) {
    if (run.state === "planned") {
        // A missing Wagenreihung (bahn.de blocked or down) doesn't cost the run; it goes on without one.
        const formation = await fetchFormation(run, fetchUpstream).catch(() => null);
        const arrival = berlinToUnix(run.planned_arrival);
        return db => db.prepare("UPDATE runs SET state = 'formed', formation = ?, attempts = 0, next_check = ? WHERE key = ?")
            .bind(formation ? JSON.stringify(formation) : null, Math.max(now, arrival + AFTER_ARRIVAL), run.key);
    }

    const details = await fetchJourney(run.journey_id, fetchUpstream);
    if (details === null) return drop(run);
    const parsed = parseJourney(details, run.journey_id);
    if (!parsed) return drop(run);

    if (run.state === "new") {
        // Only trains that stop somewhere in Germany, and no S-Bahn or buses.
        if (!parsed.stops.some(stop => stop.eva?.startsWith("80")) || EXCLUDED_CATEGORIES.has(parsed.category.toUpperCase())) return drop(run);
        const departure = berlinToUnix(parsed.plannedDeparture);
        const arrival = berlinToUnix(parsed.plannedArrival);
        // The Wagenreihung is asked for at the first stop, 10 minutes before departure. A train
        // already gone by more than a quarter of an hour skips it: bahn.de no longer has it there.
        const askFormation = departure - now > -15 * MINUTE;
        return db => db.prepare(
            "UPDATE runs SET state = ?, attempts = 0, next_check = ?, service_day = ?, name = ?, category = ?, number = ?, line = ?, " +
            "origin_eva = ?, destination_eva = ?, planned_departure = ?, planned_arrival = ? WHERE key = ?",
        ).bind(askFormation ? "planned" : "formed",
            askFormation ? Math.max(now, departure - 10 * MINUTE) : Math.max(now, arrival + AFTER_ARRIVAL),
            parsed.plannedDeparture.slice(0, 10), parsed.name, parsed.category, parsed.number, parsed.line,
            parsed.originEva, parsed.destinationEva, parsed.plannedDeparture, parsed.plannedArrival, run.key);
    }

    // state "formed": the final look. Still running late → again half an hour after it's now expected.
    const expected = berlinToUnix(parsed.expectedArrival);
    if (expected + AFTER_ARRIVAL > now && now - berlinToUnix(parsed.plannedArrival) < GIVE_UP_AFTER) {
        return db => db.prepare("UPDATE runs SET next_check = ? WHERE key = ?").bind(expected + AFTER_ARRIVAL, run.key);
    }
    // Only runs with realtime data count; without any, DB had no live information on the train.
    if (!parsed.hasRealtime) return drop(run);
    return db => [
        db.prepare("UPDATE runs SET state = 'done', completed_at = ?, final_delay = ?, cancelled = ?, messages = ?, stops = ? WHERE key = ?")
            .bind(now, parsed.finalDelay, parsed.cancelled ? 1 : 0, parsed.messages.length > 0 ? JSON.stringify(parsed.messages) : null,
                JSON.stringify(compactStops(parsed.stops, run.planned_departure ?? parsed.plannedDeparture)), run.key),
        // Station names once each, in one statement (D1 allows 50 per invocation on the free plan);
        // a station already known writes nothing.
        db.prepare("INSERT OR IGNORE INTO stations (eva, name) SELECT value->>0, value->>1 FROM json_each(?)")
            .bind(JSON.stringify(parsed.stationNames)),
    ];
}

function drop(run) {
    return db => db.prepare("DELETE FROM runs WHERE key = ?").bind(run.key);
}

/// bahn.de failed (blocked, offline, 5xx): again in 10 minutes, at most 5 times.
function retry(run, now) {
    if (run.attempts + 1 >= MAX_ATTEMPTS) return drop(run);
    return db => db.prepare("UPDATE runs SET attempts = attempts + 1, next_check = ? WHERE key = ?").bind(now + 10 * MINUTE, run.key);
}

// MARK: - bahn.de

/// bahn.de's journey details, null when it doesn't know the journey (any other failure throws).
async function fetchJourney(journeyId, fetchUpstream) {
    const response = await fetchUpstream(`${UPSTREAM}reiseloesung/fahrt?journeyId=${encodeURIComponent(journeyId)}&poly=false`,
        { headers: upstreamHeaders() });
    if (response.status === 404 || response.status === 400) return null;
    if (!response.ok) throw new Error(`bahn.de ${response.status}`);
    return response.json();
}

/// The coach sequence at the first stop, summarised; null when bahn.de has none (any other failure throws).
async function fetchFormation(run, fetchUpstream) {
    if (!run.category || !run.number || !run.origin_eva || !run.planned_departure) return null;
    const query = new URLSearchParams({
        administrationId: "80", category: run.category, date: run.planned_departure.slice(0, 10),
        evaNumber: run.origin_eva, number: run.number,
        time: new Date(berlinToUnix(run.planned_departure) * 1000).toISOString(),
    });
    const response = await fetchUpstream(`${UPSTREAM}reisebegleitung/wagenreihung/vehicle-sequence?${query}`, { headers: upstreamHeaders() });
    if (response.status === 404 || response.status === 400) return null;
    if (!response.ok) throw new Error(`bahn.de ${response.status}`);
    return summarizeFormation(await response.json());
}

export function summarizeFormation(sequence) {
    const groups = (sequence?.groups ?? []).map(group => ({
        name: group.name ?? null,
        category: group.transport?.category ?? null,
        number: group.transport?.number ?? null,
        destination: group.transport?.destination?.name ?? null,
        vehicles: (group.vehicles ?? []).map(vehicle => ({ type: vehicle.type?.constructionType ?? null, id: vehicle.vehicleID ?? null })),
    }));
    return groups.length > 0 ? { status: sequence.sequenceStatus ?? null, groups } : null;
}

/// bahn.de's journey details as one run: its train, its stops with planned and realtime times and
/// platforms, cancellations and messages. Null without stops.
export function parseJourney(details, journeyId) {
    const halts = Array.isArray(details?.halte) ? details.halte : [];
    const stops = halts.map(parseStop).filter(stop => stop.eva);
    if (stops.length === 0) return null;
    const fields = journeyFields(journeyId);
    const name = (details.zugName ?? fields.ZB ?? "").replace(/\s+/g, " ").trim();
    const [category = fields.CA ?? "", number = fields.ZE ?? ""] = name.split(" ");
    const first = stops.find(stop => stop.dep) ?? stops[0];
    const last = stops.findLast(stop => stop.arr) ?? stops[stops.length - 1];
    const served = stops.filter(stop => !stop.cancelled && stop.arr);
    const lastServed = served[served.length - 1];
    const cancelled = details.cancelled === true || stops.every(stop => stop.cancelled);
    const messages = unique([...(details.himMeldungen ?? []), ...(details.priorisierteMeldungen ?? []), ...(details.meldungen ?? [])].map(messageText));
    return {
        name,
        category: fields.CA && !/^\d+$/.test(category) ? category : (fields.CA ?? category),
        number: fields.ZE ?? number,
        // Regional trains carry their line in the name ("RE 3") and their run number in the ID.
        line: fields.ZE && number !== fields.ZE ? name : null,
        originEva: first.eva,
        destinationEva: last.eva,
        plannedDeparture: first.dep ?? first.arr,
        plannedArrival: last.arr ?? last.dep,
        expectedArrival: last.arrRt ?? last.arr ?? last.dep,
        finalDelay: lastServed?.arrDelay ?? null,
        cancelled,
        hasRealtime: cancelled || stops.some(stop => stop.arrRt || stop.depRt || stop.cancelled || stop.platformRt),
        messages,
        stops,
        stationNames: stops.map(stop => [stop.eva, stop.name]).filter(([, stationName]) => stationName),
    };
}

/// The stops as stored: one array per stop, minutes relative to the first stop's planned departure, so a
/// run takes well under a kilobyte (see schema.sql for the columns).
export function compactStops(stops, start) {
    const offset = time => time ? minutesBetween(start, time) : null;
    return stops.map(stop => {
        const flags = (stop.cancelled ? 1 : 0) | (stop.additional ? 2 : 0);
        const row = [stop.eva, offset(stop.arr), stop.arrDelay, offset(stop.dep), stop.depDelay,
            stop.platform, stop.platformRt && stop.platformRt !== stop.platform ? stop.platformRt : null, flags];
        if (stop.messages.length > 0) row.push(stop.messages);
        return row;
    });
}

function parseStop(halt) {
    const eva = halt.extId ?? halt.evaNumber ?? hafasField(halt.id, "L") ?? null;
    const arr = localTime(halt.ankunft?.sollzeit ?? halt.ankunftsZeitpunkt);
    const arrRt = localTime(halt.ankunft?.echtzeit ?? halt.ezAnkunftsZeitpunkt);
    const dep = localTime(halt.abfahrt?.sollzeit ?? halt.abfahrtsZeitpunkt);
    const depRt = localTime(halt.abfahrt?.echtzeit ?? halt.ezAbfahrtsZeitpunkt);
    const prioritised = halt.priorisierteMeldungen ?? [];
    const notes = halt.risNotizen ?? halt.risMeldungen ?? [];
    return {
        eva,
        name: halt.name ?? null,
        arr, arrRt, arrDelay: minutesBetween(arr, arrRt),
        dep, depRt, depDelay: minutesBetween(dep, depRt),
        platform: halt.gleis ?? null,
        platformRt: halt.ezGleis ?? null,
        cancelled: halt.canceled === true || prioritised.some(m => m?.type === "HALT_AUSFALL")
            || notes.some(n => n?.key === "text.realtime.stop.cancelled"),
        additional: halt.additional === true || prioritised.some(m => m?.text === "Zusatzhalt"),
        messages: unique([...prioritised, ...notes, ...(halt.himMeldungen ?? [])].map(messageText)),
    };
}

function messageText(message) {
    if (typeof message === "string") return message;
    return message?.text ?? message?.value ?? message?.ueberschrift ?? null;
}

function unique(texts) {
    return [...new Set(texts.filter(text => typeof text === "string" && text.trim()).map(text => text.trim()))];
}

function hafasField(id, name) {
    return (id ?? "").split("@").map(part => part.split("=")).find(([key]) => key === name)?.[1] ?? null;
}

// MARK: - Time

/// bahn.de's zone-less Berlin times ("2026-10-06T18:30:00") shortened to minutes, "2026-10-06T18:30".
export function localTime(text) {
    const match = typeof text === "string" && text.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/);
    return match ? `${match[1]}T${match[2]}` : null;
}

function minutesBetween(planned, actual) {
    if (!planned || !actual) return null;
    return Math.round((Date.parse(`${actual}:00Z`) - Date.parse(`${planned}:00Z`)) / 60000);
}

const berlinOffset = new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Berlin", timeZoneName: "longOffset" });

/// Unix seconds of a Berlin local time ("2026-10-06T18:30").
export function berlinToUnix(local) {
    if (!local) return 0;
    const asUTC = Date.parse(`${local}:00Z`);
    const offsetName = berlinOffset.formatToParts(new Date(asUTC)).find(part => part.type === "timeZoneName")?.value ?? "GMT+01:00";
    const [, sign, hours, minutes = "0"] = offsetName.match(/GMT([+-])(\d{2}):?(\d{2})?/) ?? [, "+", "01"];
    const offset = (Number(hours) * 60 + Number(minutes)) * (sign === "-" ? -1 : 1);
    return Math.floor((asUTC - offset * 60000) / 1000);
}

export default {
    fetch(request, env) {
        return handleRequest(request, env);
    },
    scheduled(event, env, ctx) {
        ctx.waitUntil(processDueRuns(env, event.scheduledTime));
    },
};
