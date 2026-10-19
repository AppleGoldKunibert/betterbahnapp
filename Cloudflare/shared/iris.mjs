// DB's IRIS, the keyless service behind DB Timetables that bahn.expert's boards use too: a train's stop is found
// by category, number and planned time in the station's schedule for that hour (`plan`), its live times, platform
// and cancellation come from the station's change list (`fchg`), keyed by the stop's ID. As the app's
// `TimetablesClient` (Packages/BetterBahnKit/Sources/BetterBahnKit/Transit/Timetables/TimetablesClient.swift).
// Used by `betterbahn-live` (Live Activities) and `betterbahn-push` (regular trips).

export const IRIS = "https://iris.noncd.db.de/iris-tts/timetable/";
const TIMEOUT = 8000;
// IRIS answers these for "no such data" (as bahn.expert and the bahn.de proxy treat them).
const NO_DATA_STATUSES = new Set([400, 404, 410]);
/// A stop only counts as the train's when its planned time is this close (`TimetablesClient.matchTolerance`).
const MATCH_TOLERANCE = 180;

/// Big stations whose S-Bahn platforms IRIS lists as a station of their own (`TimetablesClient.lowerLevels`).
export const LOWER_LEVELS = {
    "8000261": ["8098263"], // München Hbf (tief)
    "8000096": ["8098096"], // Stuttgart Hbf (tief)
    "8000105": ["8098105"], // Frankfurt (Main) Hbf (tief)
    "8002549": ["8098549"], // Hamburg Hbf (S-Bahn)
    "8010205": ["8098205"], // Leipzig Hbf (tief)
    "8011160": ["8098160", "8089021"], // Berlin Hbf (tief), Berlin Hbf (S-Bahn)
};

/// IRIS's answers for one cron run: each path is asked once, however many activities need it.
export class Iris {
    constructor(fetchUpstream) {
        // Called as a plain function: Cloudflare's `fetch` refuses to run as a method of this object.
        this.fetchUpstream = fetchUpstream;
        this.answers = new Map();
    }

    /// The XML at `path`, null for IRIS's "no data"; throws when IRIS can't be reached.
    text(path) {
        if (!this.answers.has(path)) this.answers.set(path, this.load(path));
        return this.answers.get(path);
    }

    async load(path) {
        const fetchUpstream = this.fetchUpstream;
        const response = await fetchUpstream(IRIS + path, { headers: { Accept: "application/xml" }, signal: AbortSignal.timeout(TIMEOUT) });
        if (NO_DATA_STATUSES.has(response.status)) return null;
        if (!response.ok) throw new Error(`IRIS ${response.status}`);
        return response.text();
    }
}

// MARK: - Finding a train

/// Where IRIS lists the train at `eva` (or a lower level of it) on `side` ("arrival"/"departure") around
/// `planned`: `{ eva, id, platform }` (its planned platform), or false when it doesn't. Throws when IRIS
/// can't be reached, so it is tried again.
export async function findStop(iris, { eva, category, number, planned, side }) {
    for (const candidate of [eva, ...(LOWER_LEVELS[eva] ?? [])]) {
        const xml = await iris.text(planPath(candidate, planned));
        const stop = xml && matchStop(parseStops(xml), category, number, planned, side);
        if (stop) return withoutEmpty({ eva: candidate, id: stop.id, platform: stop[side].plannedPlatform });
    }
    return false;
}

/// The stop's change on `side` in the station's change list: `{ actual, actualPlatform, cancelled }`, null when
/// IRIS lists no change there, undefined when the list can't be had (then nothing is known).
export async function liveChange(iris, ref, side) {
    const xml = await iris.text(`fchg/${ref.eva}`);
    if (xml === null) return undefined;
    return changedStop(xml, ref.id)?.[side] ?? null;
}

/// The hour's schedule at `eva` that holds `seconds` (German time): "plan/8000105/261017/14".
export function planPath(eva, seconds) {
    const time = berlinTime(seconds);
    return `plan/${eva}/${time.year}${time.month}${time.day}/${time.hour}`;
}

/// The train `category` + `number` whose planned `side` time is closest to `planned` (within the tolerance).
/// The same number counts under another category too, as for private operators (`TimetablesClient.match`).
export function matchStop(stops, category, number, planned, side) {
    const sameNumber = stops.filter(stop => stop.number != null && sameTrainNumber(stop.number, number));
    const sameCategory = sameNumber.filter(stop => isCategory(stop, category));
    return closest(sameCategory, planned, side) ?? closest(sameNumber, planned, side);
}

function closest(stops, planned, side) {
    let found = null, distance = Infinity;
    for (const stop of stops) {
        const time = stop[side]?.planned;
        if (time == null || Math.abs(time - planned) >= distance) continue;
        found = stop;
        distance = Math.abs(time - planned);
    }
    return distance <= MATCH_TOLERANCE ? found : null;
}

/// IRIS's numbers sometimes carry leading zeros.
function sameTrainNumber(a, b) {
    return /^[+-]?\d+$/.test(a) && /^[+-]?\d+$/.test(b) ? Number(a) === Number(b) : a === b;
}

/// DB's own category ("ICE", "NX") or the letters of the line passengers see ("RE1" → "RE").
function isCategory(stop, category) {
    const wanted = category.toUpperCase();
    return stop.category?.toUpperCase() === wanted || categoryOf(stop.lineName) === wanted;
}

/// "ICE 571" → "ICE", "S15" → "S" (`TimetablesClient.category(from:)`).
export function categoryOf(lineName) {
    const first = lineName?.split(" ").find(Boolean);
    const letters = first?.match(/^\D*/)[0];
    return letters ? letters.toUpperCase() : null;
}

// MARK: - XML

/// Every `<s>` of a `plan` answer with an arrival or departure.
export function parseStops(xml) {
    const stops = [];
    for (const [element] of xml.matchAll(/<s\b[^>]*?(?:\/>|>[\s\S]*?<\/s>)/g)) {
        const stop = parseStop(element);
        if (stop.id && (stop.arrival || stop.departure)) stops.push(stop);
    }
    return stops;
}

/// The `<s>` with `id` in a (large) `fchg` answer, without parsing the rest.
export function changedStop(xml, id) {
    const needle = `id="${escapeAttribute(id)}"`;
    for (let at = xml.indexOf(needle); at >= 0; at = xml.indexOf(needle, at + needle.length)) {
        const start = xml.lastIndexOf("<s ", at);
        if (start < 0) return null;
        const element = xml.slice(start).match(/^<s\b[^>]*?(?:\/>|>[\s\S]*?<\/s>)/)?.[0];
        if (!element) continue;
        const stop = parseStop(element);
        if (stop.id === id) return stop;
    }
    return null;
}

function parseStop(element) {
    const own = attributes(element.match(/^<s\b([^>]*)>/)[1]);
    const label = attributes(element.match(/<tl\b([^>]*)>/)?.[1] ?? "");
    const arrival = attributes(element.match(/<ar\b([^>]*)>/)?.[1] ?? "");
    const departure = attributes(element.match(/<dp\b([^>]*)>/)?.[1] ?? "");
    return {
        id: own.id,
        category: label.c ?? null,
        number: label.n ?? null,
        lineName: arrival.l ?? departure.l ?? null,
        arrival: event(arrival),
        departure: event(departure),
    };
}

/// An `<ar>`/`<dp>`: planned/changed time (`pt`/`ct`), planned/changed platform (`pp`/`cp`), status `cs` ("c":
/// cancelled). `fchg` reports a cancellation with the status alone.
function event(attributes) {
    const planned = parseTime(attributes.pt), actual = parseTime(attributes.ct);
    const cancelled = attributes.cs === "c";
    // A platform change alone comes without a time.
    if (planned === null && actual === null && !cancelled && !nonBlank(attributes.cp)) return null;
    return { planned, actual, plannedPlatform: nonBlank(attributes.pp), actualPlatform: nonBlank(attributes.cp), cancelled };
}

function attributes(text) {
    const result = {};
    for (const [, name, value] of text.matchAll(/([\w-]+)="([^"]*)"/g)) result[name] = unescapeXML(value);
    return result;
}

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'" };

function unescapeXML(text) {
    return text.replace(/&(#\d+|#x[0-9a-f]+|amp|lt|gt|quot|apos);/gi, (_, name) => name[0] === "#"
        ? String.fromCodePoint(name[1].toLowerCase() === "x" ? parseInt(name.slice(2), 16) : Number(name.slice(1)))
        : ENTITIES[name.toLowerCase()]);
}

function escapeAttribute(text) {
    return text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

function nonBlank(text) {
    return text && text.trim() ? text : null;
}

function withoutEmpty(object) {
    return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== null && value !== undefined));
}

// MARK: - German time

const BERLIN = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Berlin", hourCycle: "h23", year: "2-digit", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
});

function berlinTime(seconds) {
    return Object.fromEntries(BERLIN.formatToParts(new Date(seconds * 1000)).map(part => [part.type, part.value]));
}

/// IRIS's "YYMMDDHHmm" in German time → Unix seconds; null for anything else.
export function parseTime(text) {
    if (!/^\d{10}$/.test(text ?? "")) return null;
    const [year, month, day, hour, minute] = [0, 2, 4, 6, 8].map(index => Number(text.slice(index, index + 2)));
    const asUTC = Date.UTC(2000 + year, month - 1, day, hour, minute) / 1000;
    // Germany is an hour or two ahead of UTC: take the offset at about that moment, then at the result.
    const guess = asUTC - berlinOffset(asUTC);
    return asUTC - berlinOffset(guess);
}

/// How far German time is ahead of UTC at `seconds`, in seconds.
function berlinOffset(seconds) {
    const time = berlinTime(seconds);
    const shown = Date.UTC(2000 + Number(time.year), Number(time.month) - 1, Number(time.day), Number(time.hour), Number(time.minute)) / 1000;
    return shown - Math.floor(seconds / 60) * 60;
}
