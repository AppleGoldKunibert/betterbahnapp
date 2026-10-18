// The Live Activity's state worked out from a journey (the app's `LiveActivityPushJourney`), as the app's
// `TripActivityAttributes.ContentState.from(_:)` and `LiveActivityRefreshSchedule` do
// (Packages/BetterBahnKit/Sources/BetterBahnKit/LiveActivity/), so a push shows what the app would have shown.
// Keep them in step: both test suites check the same fixture (`Fixtures/live-activity-push.json` in the Kit tests).
//
// Times are Unix seconds here; `encodeState` turns them into what ActivityKit decodes (seconds since 2001).

const MINUTE = 60;
/// Seconds from 1970 to 2001: ActivityKit decodes the state's dates as Swift's `Date` does by default.
const REFERENCE_DATE = 978307200;
/// How long the activity stays up after the final arrival (`TripActivityAttributes.arrivedDisplayDuration`).
export const ARRIVED_DISPLAY_DURATION = 5 * MINUTE;

export const best = (time) => time.actual ?? time.planned;

/// Swift's `rounded()`: halves away from zero.
const rounded = (value) => Math.sign(value) * Math.round(Math.abs(value));

/// `TimeInfo.delayMinutes`: null without a live time.
export const delayMinutes = (time) => (time.actual == null ? null : rounded((time.actual - time.planned) / 60) || 0);

const platformBest = (platform) => platform?.actual ?? platform?.planned ?? null;

/// The track number without its sector ("7 A–C" → "7"), as `PlatformInfo.track`.
function track(platform) {
    const digits = platform?.replace(/^[ \t]+|[ \t]+$/g, "").match(/^\d*/)[0];
    return digits ? digits : null;
}

/// `ContentState.replacedPlatform`: the planned platform when the train now uses another track.
export function replacedPlatform(platform) {
    const planned = track(platform?.planned), actual = track(platform?.actual);
    return planned !== null && actual !== null && planned !== actual ? platform.planned : null;
}

/// `ContentState.init`: optional values left out (Swift encodes nil by leaving the key out), the progress
/// at least a minute long, the night-train flag only when set.
function make(fields) {
    const state = {
        lineName: fields.lineName,
        nextStopName: fields.nextStopName,
        plannedTime: fields.plannedTime,
        expectedTime: fields.expectedTime,
        platform: fields.platform,
        isDeparture: fields.isDeparture,
        cancelled: fields.cancelled,
        progressStart: fields.progressStart,
        progressEnd: Math.max(fields.progressEnd, fields.progressStart + MINUTE),
        product: fields.product,
        transfer: fields.transfer,
        currentDelayMinutes: fields.currentDelayMinutes,
        transferPlatform: fields.transferPlatform,
        replacedPlatform: fields.replacedPlatform,
        nightTrainFlag: fields.night ? true : null,
    };
    return withoutEmpty(state);
}

function withoutEmpty(object) {
    return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== null && value !== undefined));
}

/// `ContentState.base`: the next departure before boarding, the next arrival while riding.
function baseState(legs, now) {
    if (legs.length === 0) return null;
    let previousArrival = Math.min(now, best(legs[0].departure) - 30 * MINUTE);
    let previousLeg = null;
    for (const [index, leg] of legs.entries()) {
        if (now < best(leg.departure)) {
            const transfer = previousLeg && best(leg.departure) - now <= 10 * MINUTE
                ? withoutEmpty({
                    incomingLine: previousLeg.line,
                    incomingPlannedArrival: previousLeg.arrival.planned,
                    incomingExpectedArrival: best(previousLeg.arrival),
                    incomingPlatform: platformBest(previousLeg.arrivalPlatform),
                })
                : null;
            return make({
                lineName: leg.line, nextStopName: leg.origin, plannedTime: leg.departure.planned,
                expectedTime: best(leg.departure), platform: platformBest(leg.departurePlatform), isDeparture: true,
                cancelled: leg.cancelled, progressStart: previousArrival, progressEnd: best(leg.departure),
                product: leg.product, transfer, currentDelayMinutes: delayMinutes(leg.departure) ?? 0,
                replacedPlatform: replacedPlatform(leg.departurePlatform), night: leg.night,
            });
        }
        // Stays on this leg for a minute after arrival (see the app), never past the next leg's departure.
        let holdUntil = best(leg.arrival) + MINUTE;
        if (index + 1 < legs.length) holdUntil = Math.min(holdUntil, Math.max(best(leg.arrival), best(legs[index + 1].departure)));
        if (now < holdUntil) {
            const showsTransfer = index + 1 < legs.length && best(leg.arrival) - now <= 10 * MINUTE;
            return make({
                lineName: leg.line, nextStopName: leg.destination, plannedTime: leg.arrival.planned,
                expectedTime: best(leg.arrival), platform: platformBest(leg.arrivalPlatform), isDeparture: false,
                cancelled: leg.cancelled, progressStart: best(leg.departure), progressEnd: best(leg.arrival),
                product: leg.product, currentDelayMinutes: nextStopDelay(leg, now),
                transferPlatform: showsTransfer ? platformBest(legs[index + 1].departurePlatform) : null,
                replacedPlatform: showsTransfer ? replacedPlatform(legs[index + 1].departurePlatform) : null,
                night: leg.night,
            });
        }
        previousArrival = best(leg.arrival);
        previousLeg = leg;
    }
    const last = legs[legs.length - 1];
    return make({
        lineName: last.line, nextStopName: last.destination, plannedTime: last.arrival.planned,
        expectedTime: best(last.arrival), platform: platformBest(last.arrivalPlatform), isDeparture: false,
        cancelled: last.cancelled, progressStart: best(last.departure), progressEnd: best(last.arrival),
        product: last.product, currentDelayMinutes: delayMinutes(last.arrival) ?? 0, night: last.night,
    });
}

/// Delay at the next stop the train has yet to reach; else at the leg's arrival.
function nextStopDelay(leg, now) {
    const next = (leg.stops ?? []).find(stop => best(stop.arrival) >= now);
    return delayMinutes(next ? next.arrival : leg.arrival) ?? 0;
}

/// The title of the first blocking `ConnectionIssue`: a cancelled train, else a transfer under a minute.
function warning(legs) {
    const cancelled = legs.find(leg => leg.cancelled);
    if (cancelled) return `${cancelled.line} fällt aus`;
    for (let index = 1; index < legs.length; index++) {
        const arriving = legs[index - 1], departing = legs[index];
        if (arriving.cancelled || departing.cancelled) continue;
        const buffer = Math.floor((best(departing.departure) - best(arriving.arrival)) / 60);
        if (buffer < 1) return `Umstieg in ${departing.origin} klappt nicht mehr`;
    }
    return null;
}

function withWarning(legs, now) {
    const state = baseState(legs, now);
    const text = warning(legs);
    return state && text ? { ...state, warning: text } : state;
}

/// `ContentState.followUpDate`: when the state moves on (its stale date).
export const followUpDate = (state) => (state.isDeparture ? state.expectedTime : state.expectedTime + MINUTE);

export const isArrived = (state) => state?.arrivedFlag === true;

/// `ContentState.from(_:now:)`: the state at `now` and, as `followUpStorage`, the one after its follow-up date.
export function contentState(journey, now) {
    const legs = journey.legs;
    const state = withWarning(legs, now);
    if (!state) return null;
    const last = legs[legs.length - 1];
    const finalArrival = !state.isDeparture && state.expectedTime === best(last.arrival) && state.nextStopName === last.destination;
    if (finalArrival) {
        const arrived = { ...state, arrivedFlag: true };
        if (now >= followUpDate(state)) return arrived;
        return { ...state, followUpStorage: [arrived] };
    }
    const next = withWarning(legs, followUpDate(state) + 1);
    return next && !sameState(next, state) ? { ...state, followUpStorage: [next] } : state;
}

/// Whether two states (or follow-ups) are the same, whatever order their keys came in.
export function sameState(a, b) {
    return canonical(a) === canonical(b);
}

/// JSON with sorted keys, to store and compare states.
export function canonical(value) {
    if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
    if (value && typeof value === "object") {
        return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
    }
    return JSON.stringify(value);
}

/// Whether `next` is only what `previous` said would follow (the activity already shows it by itself).
export function movedOnAsPlanned(previous, next) {
    const expected = previous?.followUpStorage?.[0];
    if (!expected) return false;
    const { followUpStorage, ...rest } = next;
    return sameState(expected, rest);
}

const DATE_KEYS = ["plannedTime", "expectedTime", "progressStart", "progressEnd", "incomingPlannedArrival", "incomingExpectedArrival"];

/// The state as the push's `content-state`: dates as seconds since 2001.
export function encodeState(state) {
    const result = {};
    for (const [key, value] of Object.entries(state)) {
        if (DATE_KEYS.includes(key)) result[key] = value - REFERENCE_DATE;
        else if (key === "transfer") result[key] = encodeState(value);
        else if (key === "followUpStorage") result[key] = value.map(encodeState);
        else result[key] = value;
    }
    return result;
}

/// `LiveActivityRefreshSchedule.nextRefresh`: every 2 minutes, 1 minute before, at and after each arrival,
/// every minute while transferring.
export function nextRefresh(journey, now) {
    const regular = now + 2 * MINUTE;
    const legs = journey.legs;
    for (const [index, leg] of legs.entries()) {
        const arrival = best(leg.arrival);
        const arrivalCheckEnd = arrival + MINUTE;
        if (now < arrivalCheckEnd) {
            const nextCheck = [arrival - MINUTE, arrival, arrivalCheckEnd].find(check => check > now);
            return Math.min(regular, nextCheck ?? regular);
        }
        if (index + 1 < legs.length && now < best(legs[index + 1].departure)) return now + MINUTE;
    }
    return regular;
}
