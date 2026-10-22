// Regular trips (#397) for the `betterbahn-push` Worker: when the user said yes to "Fährst du heute?", the
// app hands over that day's journey – train category and number, boarding and exit station (EVA number)
// with their planned times, the delay threshold – and this Worker looks at DB's own timetable feed (IRIS,
// keyless) every few minutes until the journey has arrived. It pushes a cancellation, a delay from the
// threshold on (again when it grew by another 5 minutes), a platform change and a transfer at risk, the
// same rules and texts as the app (`CommuteAlerts`, `ConnectionIssue`, `PlatformChange`). It never asks
// bahn.de (#334). Stored per device: the APNs device token and those journeys. No location, no account.

import { APNs } from "../shared/apns.mjs";
import { Iris, findStop, liveChange, parseStops, planPath } from "../shared/iris.mjs";

const MINUTE = 60 * 1000;
const ID_PATTERN = /^[0-9a-f]{32}$/;
const SECRET_PATTERN = /^[0-9a-f]{64}$/;
const DEVICE_TOKEN_PATTERN = /^[0-9a-f]{64,200}$/;
const MAX_JOURNEYS = 4;
const MAX_LEGS = 6;
/// Journeys are looked at from this long before their first departure …
const LOOK_BEFORE = 2 * 60 * MINUTE;
/// … until this long after their last arrival, and forgotten after `FORGET_AFTER`.
const LOOK_AFTER = 10 * MINUTE;
const FORGET_AFTER = 30 * MINUTE;
/// A train reported late is reported again once it is this many minutes later still.
const DELAY_GROWTH = 5;
/// Platform changes are news only this close to the train (as in the app).
const PLATFORM_WINDOW = 2 * 60 * MINUTE;

// MARK: - HTTP

/// PUT /commutes/<id> { secret, deviceToken, sandbox, journeys: [{ id, threshold, legs: [{ line, category,
/// number, from: { eva, name, time }, to: { eva, name, time } }] }] } → 200 { watched: [journey id] }.
///
/// Replaces what is looked at for this device; the first PUT with an ID signs the device up, an empty list
/// signs it off. `watched` names the journeys whose every train was found in IRIS' schedule: the app reports
/// the others itself.
export async function handleCommute(id, body, env, now, fetchUpstream) {
    const { secret, deviceToken, sandbox } = body;
    if (!ID_PATTERN.test(id)) return json(404, { error: "not_found" });
    if (typeof secret !== "string" || !SECRET_PATTERN.test(secret)) return json(400, { error: "invalid_secret" });
    if (typeof deviceToken !== "string" || !DEVICE_TOKEN_PATTERN.test(deviceToken)) return json(400, { error: "invalid_device_token" });
    const journeys = validJourneys(body.journeys);
    if (!journeys) return json(400, { error: "invalid_journeys" });

    const row = await env.DB.prepare("SELECT secret_hash, journeys FROM commutes WHERE id = ?").bind(id).first();
    const secretHash = await sha256Hex(secret);
    if (row && row.secret_hash !== secretHash) return json(404, { error: "not_found" });
    if (journeys.length === 0) {
        if (row) await env.DB.prepare("DELETE FROM commutes WHERE id = ?").bind(id).run();
        return json(200, { watched: [] });
    }

    // Trains already found keep what was found and reported about them.
    const known = new Map((row ? JSON.parse(row.journeys) : []).map(journey => [journey.id, journey]));
    const iris = new Iris(fetchUpstream);
    const watched = [];
    for (const journey of journeys) {
        const before = known.get(journey.id);
        const legs = [];
        for (const [index, leg] of journey.legs.entries()) {
            const old = before?.legs[index];
            if (old && sameLeg(old, leg)) {
                legs.push(old);
                continue;
            }
            const departure = await scheduled(iris, leg, leg.from, "departure");
            const arrival = await scheduled(iris, leg, leg.to, "arrival");
            legs.push({ ...leg, departure, arrival, state: {} });
        }
        if (legs.every(leg => leg.departure)) {
            watched.push({ id: journey.id, threshold: journey.threshold, legs, transfers: before?.transfers ?? {} });
        }
    }

    if (watched.length === 0) {
        if (row) await env.DB.prepare("DELETE FROM commutes WHERE id = ?").bind(id).run();
    } else if (row) {
        await env.DB.prepare("UPDATE commutes SET device_token = ?, sandbox = ?, journeys = ?, updated = ? WHERE id = ?")
            .bind(deviceToken, sandbox ? 1 : 0, JSON.stringify(watched), Math.floor(now / 1000), id).run();
    } else {
        const slot = crypto.getRandomValues(new Uint8Array(1))[0] % 60;
        await env.DB.prepare(
            "INSERT INTO commutes (id, secret_hash, device_token, sandbox, journeys, slot, updated) VALUES (?, ?, ?, ?, ?, ?, ?)",
        ).bind(id, secretHash, deviceToken, sandbox ? 1 : 0, JSON.stringify(watched), slot, Math.floor(now / 1000)).run();
    }
    return json(200, { watched: watched.map(journey => journey.id) });
}

function validJourneys(journeys) {
    if (!Array.isArray(journeys) || journeys.length > MAX_JOURNEYS) return null;
    const text = (value, max) => typeof value === "string" && value.length > 0 && value.length <= max;
    const stop = (value) => value && /^\d{6,8}$/.test(value.eva) && text(value.name, 100) && Number.isSafeInteger(value.time);
    const valid = journeys.every(journey => text(journey?.id, 64) && Number.isSafeInteger(journey.threshold)
        && journey.threshold >= 1 && journey.threshold <= 60
        && Array.isArray(journey.legs) && journey.legs.length >= 1 && journey.legs.length <= MAX_LEGS
        && journey.legs.every(leg => text(leg?.line, 40) && /^[A-Z]{1,8}$/.test(leg.category) && /^\d{1,6}$/.test(leg.number)
            && stop(leg.from) && stop(leg.to)));
    if (!valid) return null;
    return journeys.map(journey => ({
        id: journey.id,
        threshold: journey.threshold,
        legs: journey.legs.map(({ line, category, number, from, to }) => ({
            line, category, number: number.replace(/^0+(?=\d)/, ""),
            from: { eva: from.eva, name: from.name, time: from.time },
            to: { eva: to.eva, name: to.name, time: to.time },
        })),
    }));
}

/// Where IRIS' schedule has `leg`'s train at `stop` on `side`: `{ eva, id, platform, planned }` (planned time in
/// milliseconds), or null when it doesn't or IRIS can't be reached.
async function scheduled(iris, leg, stop, side) {
    try {
        const ref = await findStop(iris, { eva: stop.eva, category: leg.category, number: leg.number, planned: stop.time, side });
        if (!ref) return null;
        // The plan was just loaded for this: its planned time is the one delays are counted from.
        const xml = await iris.text(planPath(ref.eva, stop.time));
        const found = xml && parseStops(xml).find(entry => entry.id === ref.id);
        return { ...ref, planned: (found?.[side]?.planned ?? stop.time) * 1000 };
    } catch {
        return null;
    }
}

function sameLeg(a, b) {
    return a.number === b.number && a.from.eva === b.from.eva && a.from.time === b.from.time
        && a.to.eva === b.to.eva && a.to.time === b.to.time;
}

// MARK: - Cron

/// Looks at the journeys due in this minute. Returns how many devices it looked at.
export async function processDueCommutes(env, now = Date.now(), deps = {}) {
    if (!env.DB) return 0;
    const fetchUpstream = deps.fetch ?? fetch;
    const interval = Math.min(60, Math.max(1, Number(env.INTERVAL_MINUTES) || 2));
    const minute = Math.floor(now / 60000) % 60;
    const { results } = await env.DB.prepare(
        "SELECT id, device_token, sandbox, journeys FROM commutes WHERE slot % ? = ?",
    ).bind(interval, minute % interval).all();

    const apns = new APNs(env, now, fetchUpstream);
    // Shared by every device in this run: one change list per station.
    const iris = new Iris(fetchUpstream);
    for (const row of results ?? []) {
        try {
            await look(row, env, now, iris, apns);
        } catch (error) {
            // IRIS or APNs unreachable: the next look tries again.
            console.log(`commute look failed: ${error?.message ?? error}`);
        }
    }
    return results?.length ?? 0;
}

/// One look at one device's journeys. Writes only when something was reported or a journey is over.
async function look(row, env, now, iris, apns) {
    const journeys = JSON.parse(row.journeys);
    const current = journeys.filter(journey => lastArrival(journey) + FORGET_AFTER > now);
    let changed = current.length !== journeys.length;
    for (const journey of current) {
        if (now < firstDeparture(journey) - LOOK_BEFORE || now > lastArrival(journey) + LOOK_AFTER) continue;
        const live = await Promise.all(journey.legs.map(leg => liveLeg(leg, iris)));
        for (const alert of alerts(journey, live, now)) {
            const result = await apns.send(row.device_token, row.sandbox, payload(journey, alert), {
                "apns-topic": env.APNS_TOPIC,
                "apns-push-type": "alert",
                "apns-priority": "10",
                "apns-collapse-id": `commute-${journey.id}-${alert.key}`,
            });
            if (result === "gone") {
                await env.DB.prepare("DELETE FROM commutes WHERE id = ?").bind(row.id).run();
                return;
            }
            // Only what was delivered counts as reported; the rest is tried again on the next look.
            if (result === "sent") {
                alert.remember();
                changed = true;
            }
        }
    }
    if (current.length === 0) {
        await env.DB.prepare("DELETE FROM commutes WHERE id = ?").bind(row.id).run();
    } else if (changed) {
        await env.DB.prepare("UPDATE commutes SET journeys = ? WHERE id = ?").bind(JSON.stringify(current), row.id).run();
    }
}

const firstDeparture = (journey) => journey.legs[0].from.time * 1000;
const lastArrival = (journey) => journey.legs.at(-1).to.time * 1000;

/// A leg as IRIS has it now: live departure and arrival (time, platform, cancelled).
async function liveLeg(leg, iris) {
    const side = async (ref, key) => {
        if (!ref) return null;
        const change = await liveChange(iris, ref, key).catch(() => undefined);
        // Without the change list nothing can be said; no entry for the train means no change.
        if (change === undefined) return null;
        return {
            planned: ref.planned,
            actual: change?.actual != null ? change.actual * 1000 : ref.planned,
            plannedPlatform: ref.platform ?? null,
            platform: change?.actualPlatform ?? ref.platform ?? null,
            cancelled: change?.cancelled ?? false,
        };
    };
    return {
        departure: await side(leg.departure, "departure"),
        arrival: await side(leg.arrival, "arrival"),
    };
}

/// What to report about `journey` now. Each alert remembers itself in the journey's state once sent.
export function alerts(journey, live, now) {
    const found = [];
    const { legs } = journey;
    legs.forEach((leg, index) => {
        const { departure, arrival } = live[index];
        const state = leg.state;
        if (departure?.cancelled || arrival?.cancelled) {
            if (!state.cancelled) {
                found.push({
                    key: `cancelled-${index}`,
                    title: `${leg.line} fällt aus`,
                    body: `Die Fahrt von ${leg.from.name} nach ${leg.to.name} findet nicht statt.`,
                    remember: () => { state.cancelled = true; },
                });
            }
            return;
        }
        if (departure && departure.actual > now) {
            const minutes = Math.round((departure.actual - departure.planned) / MINUTE);
            if (minutes >= journey.threshold && (state.delay == null || minutes >= state.delay + DELAY_GROWTH)) {
                found.push({
                    key: `delay-${index}`,
                    title: `${leg.line}: +${minutes} Min.`,
                    body: `Ab ${leg.from.name} um ${clock(departure.actual)} statt ${clock(departure.planned)}.`,
                    remember: () => { state.delay = minutes; },
                });
            }
        }
        const transferBefore = index > 0 && live[index - 1].arrival && departure
            ? Math.floor((departure.actual - live[index - 1].arrival.actual) / MINUTE) : null;
        const transferAfter = index + 1 < legs.length && arrival && live[index + 1].departure
            ? Math.floor((live[index + 1].departure.actual - arrival.actual) / MINUTE) : null;
        const platform = (event, kind, station, transfer) => {
            if (!event || event.actual < now || event.actual > now + PLATFORM_WINDOW) return;
            const key = `${kind}Platform`;
            const before = state[key] ?? event.plannedPlatform;
            if (!isDifferentTrack(before, event.platform)) return;
            const text = kind === "departure"
                ? `Abfahrt ${station} jetzt von Gleis ${event.platform} (statt ${before})`
                : `Ankunft ${station} jetzt auf Gleis ${event.platform} (statt ${before})`;
            found.push({
                key: `${kind}-platform-${index}`,
                title: `${leg.line}: Gleiswechsel`,
                body: transfer == null ? text : `${text}\nUmstieg: ${transfer} Min.`,
                remember: () => { state[key] = event.platform; },
            });
        };
        platform(departure, "departure", leg.from.name, transferBefore);
        // The destination's platform matters only for a transfer there.
        if (index + 1 < legs.length) platform(arrival, "arrival", leg.to.name, transferAfter);

        if (index > 0 && transferBefore != null && departure.actual > now) {
            const previous = legs[index - 1];
            const plannedBuffer = Math.floor((departure.planned - live[index - 1].arrival.planned) / MINUTE);
            const level = transferBefore < 1 ? "missed" : transferBefore < 5 && plannedBuffer >= 5 ? "risk" : null;
            const reported = journey.transfers[index];
            if (level && level !== reported && reported !== "missed") {
                const at = leg.from.name;
                found.push({
                    key: `transfer-${index}`,
                    title: level === "missed" ? `Umstieg in ${at} klappt nicht mehr` : `Umstieg in ${at} wird knapp`,
                    body: level === "risk" || transferBefore >= 0
                        ? `${level === "missed" ? "Nur " : ""}${transferBefore} Min. zum Umsteigen von ${previous.line} in ${leg.line}.`
                        : `${leg.line} fährt ${-transferBefore} Min. bevor ${previous.line} ankommt.`,
                    remember: () => { journey.transfers[index] = level; },
                });
            }
        }
    });
    return found;
}

function payload(journey, alert) {
    return {
        aps: {
            alert: { title: alert.title, body: alert.body },
            sound: "default",
            "interruption-level": "time-sensitive",
            "thread-id": `commute-${journey.id}`,
        },
        commuteJourneyID: journey.id,
    };
}

/// The track number without its sector ("7 A-C" → "7"); platforms without a number can't be compared.
function track(platform) {
    const digits = String(platform ?? "").trim().match(/^\d+/);
    return digits ? digits[0] : null;
}

function isDifferentTrack(a, b) {
    const first = track(a), second = track(b);
    return first !== null && second !== null && first !== second;
}

// MARK: - German time

function clockParts(ms) {
    return Object.fromEntries(new Intl.DateTimeFormat("en-GB", {
        timeZone: "Europe/Berlin", hour: "numeric", minute: "2-digit", hourCycle: "h23",
    }).formatToParts(new Date(ms)).map(({ type, value }) => [type, Number(value)]));
}

/// "7:42", like the app.
export function clock(ms) {
    const p = clockParts(ms);
    return `${p.hour}:${String(p.minute).padStart(2, "0")}`;
}

// MARK: - Helpers

async function sha256Hex(text) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

function json(status, body) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
    });
}
