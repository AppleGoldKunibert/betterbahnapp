// Live times for a shared journey's page (`/share/<id>/live`): every train that hasn't arrived yet is asked the way
// "Ankunft teilen" asks (`liveTrain` in arrival.mjs: DB's IRIS per stop, else bahn.de's journey details through our
// server), and the answer goes into the journey as the app stored it: the leg's times and platforms, its stops,
// whether it runs at all, and DB's notices. A train nobody can answer for keeps the times from sharing.
//
// Nothing is asked until someone opens the page: the Worker has no timer, so a link nobody looks at costs nothing,
// and the answers are cached (`worker.mjs`), so many readers of one link make one round of requests a minute.

import { liveTrain, sameStation } from "./arrival.mjs";

/// A train that arrived longer ago than this isn't asked again.
const LEG_DONE_AFTER = 10 * 60 * 1000;
/// The page shows no live data any more (and stops asking) this long after the last arrival.
const JOURNEY_DONE_AFTER = 30 * 60 * 1000;
/// Trains asked per request: the ones next in line. A later train's times don't change much before it's next anyway.
const MAX_LIVE_LEGS = 4;
const JOURNEY_ID_PATTERN = /^\d+\|#[\x20-\x7eÀ-ſ]+$/;
const MAX_MESSAGES = 5;

const best = info => info.actual ?? info.planned;

/// `view` (from `journeyView`) with DB's live times, `live` when at least one train had some, `done` once the
/// journey is over and asking is pointless. Never throws: a failing train keeps what it had.
export async function liveJourney(view, now, deps = {}) {
    const last = view.legs[view.legs.length - 1];
    const done = best(last.arrival) + JOURNEY_DONE_AFTER < now;
    const base = { updatedAt: now, live: false, done };
    if (done) return { ...view, ...base };
    const asked = view.legs
        .map((leg, index) => ({ leg, index }))
        .filter(({ leg }) => !leg.walking && best(leg.arrival) + LEG_DONE_AFTER > now)
        .slice(0, MAX_LIVE_LEGS);
    const answers = await Promise.all(asked.map(({ leg }) => legWithLiveTimes(leg, now, deps).catch(() => null)));
    const legs = [...view.legs];
    let live = false;
    asked.forEach(({ index }, position) => {
        if (!answers[position]) return;
        legs[index] = answers[position];
        live = true;
    });
    return { ...view, legs, ...base, live };
}

/// The leg with the live times of its train; null when nobody knows the train.
async function legWithLiveTimes(leg, now, deps) {
    const stops = trainStops(leg);
    if (!stops) return null;
    const train = {
        train: leg.line ?? "", number: leg.number,
        journeyId: leg.tripId && JOURNEY_ID_PATTERN.test(leg.tripId) ? leg.tripId : null,
        stops: stops.map(toLiveStop),
    };
    if (!train.train) return null;
    const answer = await liveTrain(train, { ...deps, now });
    if (!answer.live) return null;
    return merge(leg, stops, answer);
}

/// The leg's stops from where it starts to where it ends, as the app lists them (when it does): the stop
/// list on the page is left alone, and `origin` / `destination` stand in when the app had none.
function trainStops(leg) {
    const stops = [...leg.stops];
    if (stops[0]?.name !== leg.origin) {
        stops.unshift({ name: leg.origin, eva: leg.originEva, arrival: null, departure: leg.departure, arrivalPlatform: null,
            departurePlatform: leg.departurePlatform, cancelled: false, added: true });
    }
    if (stops[stops.length - 1]?.name !== leg.destination) {
        stops.push({ name: leg.destination, eva: leg.destinationEva, arrival: leg.arrival, departure: null,
            arrivalPlatform: leg.arrivalPlatform, departurePlatform: null, cancelled: false, added: true });
    }
    // IRIS and bahn.de are asked by EVA number: the leg's own ends know theirs even when the stop list doesn't.
    stops[0] = { ...stops[0], eva: stops[0].eva ?? leg.originEva };
    const end = stops.length - 1;
    stops[end] = { ...stops[end], eva: stops[end].eva ?? leg.destinationEva };
    return stops.length >= 2 && stops[end].arrival ? stops : null;
}

/// A stop as `arrival.mjs` knows it: Unix ms, one platform (where the train arrives at the last stop, else leaves).
function toLiveStop(stop, index, stops) {
    const isLast = index === stops.length - 1;
    const platform = isLast ? stop.arrivalPlatform ?? stop.departurePlatform : stop.departurePlatform ?? stop.arrivalPlatform;
    return {
        name: stop.name, eva: stop.eva,
        arr: stop.arrival?.planned ?? null, arrRt: stop.arrival?.actual ?? null,
        dep: stop.departure?.planned ?? null, depRt: stop.departure?.actual ?? null,
        platform: platform?.planned ?? null, platformRt: platform?.actual ?? null,
        cancelled: stop.cancelled,
    };
}

function withActual(info, actual) {
    return info && actual !== null && actual !== undefined ? { planned: info.planned, actual } : info;
}

function withPlatform(info, planned, actual) {
    if (!actual) return info;
    return { planned: info?.planned ?? planned ?? null, actual };
}

function merge(leg, stops, { stops: live, messages }) {
    // Each of our stops finds its live counterpart (the same list for IRIS, a section of bahn.de's for bahn.de).
    let from = 0;
    const found = stops.map(stop => {
        const index = live.findIndex((candidate, at) => at >= from && sameStation(candidate, stop));
        if (index < 0) return null;
        from = index + 1;
        return live[index];
    });
    const first = found[0];
    const end = found[found.length - 1];
    if (!first || !end) return null;

    const merged = stops.map((stop, index) => {
        const match = found[index];
        if (!match) return stop;
        const isLast = index === stops.length - 1;
        // The live platform belongs to the one `toLiveStop` took: the arrival's at the last stop, else the departure's.
        const key = isLast ? (stop.arrivalPlatform || !stop.departurePlatform ? "arrivalPlatform" : "departurePlatform")
            : (stop.departurePlatform || !stop.arrivalPlatform ? "departurePlatform" : "arrivalPlatform");
        return {
            ...stop,
            arrival: withActual(stop.arrival, match.arrRt),
            departure: withActual(stop.departure, match.depRt),
            [key]: withPlatform(stop[key], match.platform, match.platformRt),
            cancelled: match.cancelled,
        };
    });
    const shown = merged.filter(stop => !stop.added);
    const notes = [...leg.messages];
    for (const message of messages) {
        if (!notes.includes(message) && notes.length < MAX_MESSAGES) notes.push(message);
    }
    return {
        ...leg,
        departure: withActual(leg.departure, first.depRt),
        arrival: withActual(leg.arrival, end.arrRt),
        departurePlatform: withPlatform(leg.departurePlatform, first.platform, first.platformRt),
        arrivalPlatform: withPlatform(leg.arrivalPlatform, end.platform, end.platformRt),
        cancelled: first.cancelled || end.cancelled,
        stops: shown,
        messages: notes,
    };
}
