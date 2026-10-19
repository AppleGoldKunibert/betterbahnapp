// Worker `betterbahn-live`: keeps a journey's Live Activity current while the app is closed (#315).
//
// iOS runs the app's background refresh when it likes, often much later than asked, so the activity showed old
// delays and platforms until the app was opened again. When the app goes to the background it hands the journey
// and the activity's push token over (`PUT /activities/<id>`); every minute the cron trigger looks at the
// activities that are due on the app's own schedule (`nextRefresh`), lays DB's live data from IRIS over the
// train that matters now, works out the activity's state as the app would (`state.mjs`) and pushes it with
// ActivityKit's push updates when it changed. After the arrival it ends the activity and forgets the journey.
// When the app is opened again it takes over (`DELETE /activities/<id>`).

import { APNs } from "../shared/apns.mjs";
import { TOKEN_HEADER, unauthorized, verifyToken } from "../shared/appattest.mjs";
import { Iris, findStop, liveChange } from "../shared/iris.mjs";
import {
    ARRIVED_DISPLAY_DURATION, best, canonical, contentState, encodeState, followUpDate, isArrived, movedOnAsPlanned, nextRefresh,
} from "./state.mjs";

const MINUTE = 60;
/// DB lists only changes: a train it reports none for runs on time once it is this close (`TimetablesClient.onTimeLookahead`).
const ON_TIME_LOOKAHEAD = 2 * 3600;
/// How far ahead a train missing from IRIS's schedule counts as not being there at all.
const SCHEDULE_AHEAD = 3 * 3600;
/// A journey whose activity couldn't be ended is forgotten this long after its arrival anyway.
const FORGET_AFTER = 30 * MINUTE;
const ID_PATTERN = /^[0-9a-f]{32}$/;
const SECRET_PATTERN = /^[0-9a-f]{64}$/;
const PUSH_TOKEN_PATTERN = /^[0-9a-f]{32,400}$/;
const EVA_PATTERN = /^\d{7}$/;
const MAX_BODY_BYTES = 32 * 1024;

// MARK: - HTTP

/// PUT    /activities/<id> { secret, pushToken, sandbox, journey } → 200 {} (404: the ID is someone else's)
/// DELETE /activities/<id> { secret }                              → 204 (404: unknown)
export async function handleRequest(request, env = {}, now = Date.now()) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json(200, { ok: true });
    const match = url.pathname.match(/^\/activities\/([^/]+)$/);
    if (!match) return json(404, { error: "not_found" });
    if (!env.DB) return json(503, { error: "not_configured" });

    // Only the genuine app: an App Attest token (same TOKEN_SECRET as the other Workers), or no token while
    // ALLOW_UNATTESTED is "true" (see ../shared/appattest.mjs).
    const token = request.headers.get(TOKEN_HEADER);
    const claims = token && env.TOKEN_SECRET ? await verifyToken(token, "a", env.TOKEN_SECRET, now) : null;
    if (token ? !claims : env.ALLOW_UNATTESTED !== "true") return unauthorized();
    if (env.REGISTER_LIMITER) {
        const key = claims?.kid ?? request.headers.get("CF-Connecting-IP") ?? "unknown";
        const { success } = await env.REGISTER_LIMITER.limit({ key: String(key) });
        if (!success) return json(429, { error: "rate_limited" });
    }

    const id = match[1];
    if (!ID_PATTERN.test(id)) return json(404, { error: "not_found" });
    if (request.method !== "PUT" && request.method !== "DELETE") {
        return json(405, { error: "method_not_allowed" }, { Allow: "PUT, DELETE" });
    }
    let body;
    try {
        const text = await request.text();
        if (text.length > MAX_BODY_BYTES) return json(413, { error: "too_large" });
        body = JSON.parse(text);
    } catch {
        return json(400, { error: "invalid_json" });
    }
    if (typeof body?.secret !== "string" || !SECRET_PATTERN.test(body.secret)) return json(400, { error: "invalid_secret" });
    const secretHash = await sha256Hex(body.secret);
    const row = await env.DB.prepare("SELECT secret_hash FROM activities WHERE id = ?").bind(id).first();
    if (row && row.secret_hash !== secretHash) return json(404, { error: "not_found" });

    if (request.method === "DELETE") {
        if (!row) return json(404, { error: "not_found" });
        await env.DB.prepare("DELETE FROM activities WHERE id = ?").bind(id).run();
        return new Response(null, { status: 204 });
    }

    if (typeof body.pushToken !== "string" || !PUSH_TOKEN_PATTERN.test(body.pushToken)) return json(400, { error: "invalid_push_token" });
    const journey = sanitizeJourney(body.journey);
    if (!journey) return json(400, { error: "invalid_journey" });
    const seconds = Math.floor(now / 1000);
    // What the app shows right now, worked out from the same journey: only a change from it is pushed.
    const state = contentState(journey, seconds);
    const ends = best(journey.legs[journey.legs.length - 1].arrival) + ARRIVED_DISPLAY_DURATION;
    await env.DB.prepare(
        "INSERT OR REPLACE INTO activities (id, secret_hash, push_token, sandbox, journey, state, next_check, ends, created) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ).bind(id, secretHash, body.pushToken, body.sandbox ? 1 : 0, JSON.stringify(journey), state ? canonical(state) : null,
        nextRefresh(journey, seconds), ends, seconds).run();
    return json(200, {});
}

/// The journey as the app sends it (`LiveActivityPushJourney`), with only the fields used here and in their
/// types; null when it doesn't look like one.
export function sanitizeJourney(input) {
    const legs = input?.legs;
    if (!Array.isArray(legs) || legs.length === 0 || legs.length > 12) return null;
    const result = [];
    for (const leg of legs) {
        const departure = time(leg?.departure), arrival = time(leg?.arrival);
        if (!departure || !arrival || !text(leg.line) || !text(leg.origin) || !text(leg.destination) || !text(leg.product)) return null;
        if (!Array.isArray(leg.stops ?? []) || (leg.stops ?? []).length > 150) return null;
        const stops = [];
        for (const stop of leg.stops ?? []) {
            const stopArrival = time(stop?.arrival);
            if (!stopArrival) return null;
            stops.push(withoutEmpty({ eva: eva(stop.eva), arrival: stopArrival }));
        }
        const lookup = text(leg.category) && text(leg.number);
        result.push(withoutEmpty({
            line: leg.line, category: lookup ? leg.category : null, number: lookup ? leg.number : null,
            product: leg.product, night: leg.night === true, cancelled: leg.cancelled === true,
            origin: leg.origin, originEva: eva(leg.originEva), destination: leg.destination, destinationEva: eva(leg.destinationEva),
            departure, arrival, departurePlatform: platform(leg.departurePlatform), arrivalPlatform: platform(leg.arrivalPlatform),
            stops,
        }));
    }
    return { legs: result };
}

function text(value) {
    return typeof value === "string" && value.length > 0 && value.length <= 120;
}

function time(value) {
    if (!Number.isSafeInteger(value?.planned)) return null;
    if (value.actual != null && !Number.isSafeInteger(value.actual)) return null;
    return withoutEmpty({ planned: value.planned, actual: value.actual });
}

function platform(value) {
    if (value == null || typeof value !== "object") return null;
    const planned = text(value.planned) ? value.planned : null, actual = text(value.actual) ? value.actual : null;
    return planned || actual ? withoutEmpty({ planned, actual }) : null;
}

function eva(value) {
    return typeof value === "string" && EVA_PATTERN.test(value) ? value : null;
}

function json(status, body, headers = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
    });
}

// MARK: - Cron

/// Looks at the activities that are due. Returns how many it looked at.
export async function processDueActivities(env, now = Date.now(), deps = {}) {
    const fetchUpstream = deps.fetch ?? fetch;
    const seconds = Math.floor(now / 1000);
    // Free plan: 50 outgoing requests per run, each activity takes up to 7 (IRIS, APNs).
    const batch = Math.min(40, Math.max(1, Number(env.BATCH) || 6));
    const { results } = await env.DB.prepare(
        "SELECT id, push_token, sandbox, journey, state, ends FROM activities WHERE next_check <= ? ORDER BY next_check LIMIT ?",
    ).bind(seconds, batch).all();

    const iris = new Iris(fetchUpstream);
    const apns = new APNs(env, now, fetchUpstream);
    for (const activity of results ?? []) {
        try {
            await check(activity, env, seconds, iris, apns);
        } catch (error) {
            // APNs unreachable or something unexpected: again in a minute.
            console.log(`check failed: ${error?.message ?? error}`);
            await env.DB.prepare("UPDATE activities SET next_check = ? WHERE id = ?").bind(seconds + MINUTE, activity.id).run();
        }
    }
    return results?.length ?? 0;
}

/// One look at one activity: refresh, push what changed (or end it after the arrival), plan the next look.
async function check(activity, env, seconds, iris, apns) {
    const remove = () => env.DB.prepare("DELETE FROM activities WHERE id = ?").bind(activity.id).run();
    if (seconds > activity.ends + FORGET_AFTER) return remove();

    const journey = JSON.parse(activity.journey);
    await refreshJourney(journey, seconds, iris);
    const state = contentState(journey, seconds);
    if (!state) return remove();
    const send = (payload, priority) => apns.send(activity.push_token, activity.sandbox, payload, {
        "apns-topic": `${env.APNS_TOPIC}.push-type.liveactivity`,
        "apns-push-type": "liveactivity",
        "apns-priority": String(priority),
    });

    if (isArrived(state)) {
        // As the app does: "Angekommen" stays a few minutes, then the activity goes.
        await send({
            aps: {
                timestamp: seconds, event: "end", "content-state": encodeState(state),
                "dismissal-date": state.expectedTime + ARRIVED_DISPLAY_DURATION,
            },
        }, 10);
        return remove();
    }

    let stored = activity.state;
    if (canonical(state) !== activity.state) {
        // The phase moving on as the activity already shows it (`followUp`) needn't be urgent; new times are.
        const previous = activity.state ? JSON.parse(activity.state) : null;
        const result = await send({
            aps: { timestamp: seconds, event: "update", "content-state": encodeState(state), "stale-date": followUpDate(state) },
        }, movedOnAsPlanned(previous, state) ? 5 : 10);
        if (result === "gone") return remove();
        // Only what was delivered counts; otherwise it is sent again on the next look.
        if (result === "sent") stored = canonical(state);
    }
    await env.DB.prepare("UPDATE activities SET journey = ?, state = ?, next_check = ? WHERE id = ?")
        .bind(JSON.stringify(journey), stored, nextRefresh(journey, seconds), activity.id).run();
}

// MARK: - Live data

/// Lays IRIS's live data over the parts of `journey` that the activity shows at `seconds` (see `liveEvents`),
/// as the app's `TimetablesClient.realtime(for:)`: a change IRIS reports wins, a train it reports none for runs on
/// time once it is about to, and where IRIS can't be asked, what the app sent stays. Changes `journey`.
export async function refreshJourney(journey, seconds, iris) {
    const cancellations = new Map();
    for (const event of liveEvents(journey, seconds)) {
        const { leg, holder, refKey, side, time } = event;
        try {
            // Where the train is in IRIS is looked up once and kept with the journey (false: IRIS doesn't have it;
            // only believed within a few hours, IRIS's schedule doesn't reach much further ahead).
            if (holder[refKey] === undefined) {
                const found = await findStop(iris, { eva: event.eva, category: leg.category, number: leg.number, planned: time.planned, side });
                if (found || time.planned - seconds < SCHEDULE_AHEAD) holder[refKey] = found;
            }
            const ref = holder[refKey];
            if (!ref) continue;
            const change = await liveChange(iris, ref, side);
            if (change === undefined) continue;
            const onTime = leg.departure.planned - seconds < ON_TIME_LOOKAHEAD;
            const actual = change?.actual ?? time.actual ?? (onTime ? time.planned : null);
            if (actual != null) time.actual = actual;
            if (event.platformKey) {
                if (change?.actualPlatform) {
                    leg[event.platformKey] = withoutEmpty({ planned: leg[event.platformKey]?.planned, actual: change.actualPlatform });
                } else if (!leg[event.platformKey] && ref.platform) {
                    leg[event.platformKey] = { planned: ref.platform };
                }
                const known = cancellations.get(leg) ?? {};
                known[side] = change?.cancelled ?? false;
                cancellations.set(leg, known);
            }
        } catch (error) {
            // IRIS unreachable: what the app sent stays, the next look tries again.
            console.log(`IRIS failed: ${error?.message ?? error}`);
        }
    }
    // DB's verdict on a train wins once it knows both ends (or either end is cancelled).
    for (const [leg, known] of cancellations) {
        if (known.departure === true || known.arrival === true) leg.cancelled = true;
        else if (known.departure === false && known.arrival === false) leg.cancelled = false;
    }
    // The last stop is the leg's destination: it keeps the same time.
    for (const leg of journey.legs) {
        const last = leg.stops?.[leg.stops.length - 1];
        if (last && last.arrival.planned === leg.arrival.planned) last.arrival = { ...leg.arrival };
    }
}

/// What the activity shows at `seconds` and IRIS may know better: the current train's departure until it has
/// left, then its next stop (the delay shown while riding), its arrival, and the next train's departure (the
/// transfer and its warning). At most three stations, often two.
export function liveEvents(journey, seconds) {
    const legs = journey.legs;
    const index = legs.findIndex(leg => seconds < best(leg.arrival) + MINUTE);
    if (index < 0) return [];
    const leg = legs[index];
    const events = [];
    if (seconds < best(leg.departure) + 2 * MINUTE) {
        events.push(departureOf(leg));
    } else {
        const stops = leg.stops ?? [];
        const next = stops.find(stop => best(stop.arrival) >= seconds);
        if (next && next !== stops[stops.length - 1]) {
            events.push({ leg, holder: next, refKey: "ref", side: "arrival", time: next.arrival, eva: next.eva });
        }
    }
    events.push({ leg, holder: leg, refKey: "destinationRef", side: "arrival", time: leg.arrival, eva: leg.destinationEva, platformKey: "arrivalPlatform" });
    if (index + 1 < legs.length) events.push(departureOf(legs[index + 1]));
    return events.filter(event => event.leg.category && event.leg.number && event.eva);
}

function departureOf(leg) {
    return { leg, holder: leg, refKey: "originRef", side: "departure", time: leg.departure, eva: leg.originEva, platformKey: "departurePlatform" };
}

// MARK: - Helpers

function withoutEmpty(object) {
    return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== null && value !== undefined));
}

async function sha256Hex(text) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

export default {
    fetch(request, env) {
        return handleRequest(request, env);
    },
    scheduled(event, env, ctx) {
        ctx.waitUntil(processDueActivities(env, event.scheduledTime));
    },
};
