// A shared journey (`/s/<id>`) for people without the app: the Worker reads the stored payload (what the app's
// `JourneyShareLink.payload(for:)` writes: the `Journey` as JSON, raw-deflate compressed, base64url) when the
// page is asked for and draws the whole journey as a small version of the app's journey view: every leg with
// times, delays, platforms and its stops. Nothing is stored or sent anywhere else; the page needs no script.
//
// Dates in that JSON are Apple's `Date` default: seconds since 2001-01-01 UTC.

const APPLE_EPOCH_MS = 978307200 * 1000;
// Same cap as `JourneyShareLink.maxJSONSize` in the app: a small payload must not inflate to gigabytes.
export const MAX_JOURNEY_JSON = 1024 * 1024;
const MAX_LEGS = 20;
const MAX_STOPS = 300;

/// The journey stored under a share, or null when it isn't a journey this page can draw.
export async function decodeJourney(data) {
    try {
        const json = await inflate(base64URLBytes(data));
        if (!json) return null;
        return journeyView(JSON.parse(new TextDecoder().decode(json)));
    } catch {
        return null;
    }
}

function base64URLBytes(data) {
    const base64 = data.replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "="));
    return Uint8Array.from(binary, c => c.charCodeAt(0));
}

/// Raw deflate (what Apple's Compression framework writes); zlib-wrapped data is read too.
async function inflate(bytes) {
    for (const format of bytes[0] === 0x78 ? ["deflate", "deflate-raw"] : ["deflate-raw", "deflate"]) {
        const result = await inflateAs(bytes, format).catch(() => null);
        if (result) return result;
    }
    return null;
}

async function inflateAs(bytes, format) {
    const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream(format)).getReader();
    const chunks = [];
    let size = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > MAX_JOURNEY_JSON) {
            await reader.cancel();
            return null;
        }
        chunks.push(value);
    }
    const out = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
        out.set(chunk, offset);
        offset += chunk.length;
    }
    return size > 0 ? out : null;
}

// MARK: - What the page needs from the Journey

const ms = date => typeof date === "number" && Number.isFinite(date) ? Math.round(date * 1000) + APPLE_EPOCH_MS : null;
const text = value => typeof value === "string" && value.trim() ? value.trim() : null;

function time(info) {
    const planned = ms(info?.planned);
    if (planned === null) return null;
    return { planned, actual: ms(info.actual) };
}

function platform(info) {
    const planned = text(info?.planned);
    const actual = text(info?.actual);
    return planned || actual ? { planned, actual } : null;
}

/// The feed's color for an S-Bahn or U-Bahn line, as in the app (`Line.lineColorHex`): not for other trains,
/// and not when white text would be hard to read on it.
function lineColor(line) {
    const hex = line?.feedColorHex;
    if (line?.product !== "suburban" && line?.product !== "subway") return null;
    if (!Number.isInteger(hex) || hex < 0 || hex > 0xffffff) return null;
    const channel = shift => {
        const c = (hex >> shift & 0xff) / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    const luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
    return 1.05 / (luminance + 0.05) >= 2.5 ? hex : null;
}

/// The Journey's legs reduced to what the page draws; null without a usable leg.
export function journeyView(journey) {
    if (!Array.isArray(journey?.legs) || journey.legs.length === 0 || journey.legs.length > MAX_LEGS) return null;
    const legs = [];
    for (const leg of journey.legs) {
        const departure = time(leg?.departure);
        const arrival = time(leg?.arrival);
        const origin = text(leg?.origin?.name);
        const destination = text(leg?.destination?.name);
        if (!departure || !arrival || !origin || !destination) return null;
        const stops = (Array.isArray(leg.stopovers) ? leg.stopovers : []).slice(0, MAX_STOPS).flatMap(stop => {
            const name = text(stop?.station?.name);
            if (!name) return [];
            return [{
                name,
                arrival: time(stop.arrival),
                departure: time(stop.departure),
                arrivalPlatform: platform(stop.arrivalPlatform),
                departurePlatform: platform(stop.departurePlatform),
                cancelled: Boolean(stop.arrivalCancelled || stop.departureCancelled),
                access: stop.access ?? "normal",
            }];
        });
        legs.push({
            origin, destination, departure, arrival,
            departurePlatform: platform(leg.departurePlatform),
            arrivalPlatform: platform(leg.arrivalPlatform),
            line: text(leg.line?.name),
            product: typeof leg.line?.product === "string" ? leg.line.product : "other",
            color: lineColor(leg.line),
            nightTrain: leg.line?.nightRail === true,
            direction: text(leg.direction),
            walking: Boolean(leg.isWalking),
            cancelled: Boolean(leg.cancelled),
            stops,
            messages: (Array.isArray(leg.messages) ? leg.messages : []).map(m => text(m?.text)).filter(Boolean).slice(0, 5),
        });
    }
    return { legs };
}

// MARK: - Page

const escape = value => String(value ?? "").replace(/[&<>"']/g,
    c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const clock = new Intl.DateTimeFormat("de-DE", { timeZone: "Europe/Berlin", hour: "2-digit", minute: "2-digit" });
const dayFormat = new Intl.DateTimeFormat("de-DE", { timeZone: "Europe/Berlin", weekday: "long", day: "numeric", month: "long" });
const dayKey = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Berlin" });
const hhmm = value => clock.format(new Date(value));

const PRODUCT_COLORS = {
    regionalExpress: "#db1730", regional: "#db1730", suburban: "#1a994d", subway: "#1f61cc", tram: "#cc731a",
    bus: "#8547bd", coach: "#8547bd", ferry: "#1a8ccc", other: "#8e8e93",
};

const best = info => info.actual ?? info.planned;
const delayOf = info => info.actual === null ? null : Math.round((info.actual - info.planned) / 60000);
const tone = minutes => minutes === null || minutes <= 0 ? "ontime" : minutes > 10 ? "heavy" : minutes > 5 ? "slight" : "ontime";

export function durationText(minutes) {
    if (minutes < 60) return `${minutes} Min.`;
    return `${Math.floor(minutes / 60)} Std.${minutes % 60 ? ` ${minutes % 60} Min.` : ""}`;
}

function timeCell(info, className = "") {
    const delay = delayOf(info);
    if (delay === null || delay === 0) return `<span class="t ${className}">${hhmm(info.planned)}</span>`;
    return `<span class="t ${className}"><span class="${tone(delay)}">${hhmm(info.actual)}</span> <s>${hhmm(info.planned)}</s></span>`;
}

function platformText(info) {
    if (!info) return "";
    const now = info.actual ?? info.planned;
    const moved = info.actual && info.planned && info.actual !== info.planned;
    return `<span class="gl${moved ? " moved" : ""}">Gl. ${escape(now)}</span>`;
}

function badge(leg) {
    const name = escape(leg.line ?? "Zug");
    const color = leg.color !== null ? `#${leg.color.toString(16).padStart(6, "0")}`
        : PRODUCT_COLORS[leg.product] ?? "var(--long-distance)";
    return `<span class="line" style="background:${color}">${name}</span>`;
}

function stopsList(leg) {
    // The first and last stop repeat the leg's own times (when the stops include them): the ones in between expand.
    let between = leg.stops;
    if (between[0]?.name === leg.origin) between = between.slice(1);
    if (between[between.length - 1]?.name === leg.destination) between = between.slice(0, -1);
    if (between.length === 0) return "";
    const rows = between.map(stop => {
        const info = stop.arrival ?? stop.departure;
        const platformInfo = stop.arrivalPlatform ?? stop.departurePlatform;
        const through = stop.access === "passThrough";
        return `<li class="${stop.cancelled ? "cancelled" : ""}${through ? " through" : ""}">${info ? timeCell(info) : `<span class="t"></span>`}`
            + `<span class="name">${escape(stop.name)}</span>${platformText(platformInfo)}</li>`;
    }).join("");
    const label = between.length === 1 ? "1 Halt" : `${between.length} Halte`;
    return `<details class="stops"><summary>${label}</summary><ol>${rows}</ol></details>`;
}

function renderLeg(leg, next) {
    const gap = next ? Math.round((best(next.departure) - best(leg.arrival)) / 60000) : null;
    const transfer = gap === null || next.walking || leg.walking ? ""
        : gap < 0 ? `<p class="transfer heavy">Anschluss nicht erreichbar</p>`
            : `<p class="transfer${gap < 5 ? " tight" : ""}">Umstieg: ${durationText(gap)}</p>`;
    if (leg.walking) {
        const minutes = Math.max(1, Math.round((best(leg.arrival) - best(leg.departure)) / 60000));
        return `<section class="walk"><span>Fußweg von ${escape(leg.origin)} nach ${escape(leg.destination)} · ${durationText(minutes)}</span></section>${transfer}`;
    }
    const messages = leg.messages.map(m => `<p class="note">${escape(m)}</p>`).join("");
    const direction = leg.direction ? `<span class="direction">Richtung ${escape(leg.direction)}</span>` : "";
    return `<section class="card${leg.cancelled ? " cancelled" : ""}">
<p class="train">${badge(leg)}${direction}</p>
${leg.cancelled ? `<p class="pill heavy">Fällt aus</p>` : ""}
<div class="ends">
<div class="end">${timeCell(leg.departure, "big")}<span class="name">${escape(leg.origin)}</span>${platformText(leg.departurePlatform)}</div>
${stopsList(leg)}
<div class="end">${timeCell(leg.arrival, "big")}<span class="name">${escape(leg.destination)}</span>${platformText(leg.arrivalPlatform)}</div>
</div>
${messages}
</section>${transfer}`;
}

export function renderJourney(view) {
    const legs = view.legs;
    const first = legs[0];
    const last = legs[legs.length - 1];
    const transit = legs.filter(leg => !leg.walking);
    const transfers = Math.max(0, transit.length - 1);
    const minutes = Math.max(0, Math.round((best(last.arrival) - best(first.departure)) / 60000));
    const day = dayFormat.format(new Date(first.departure.planned));
    const nextDay = dayKey.format(new Date(best(last.arrival))) !== dayKey.format(new Date(best(first.departure)));
    const summary = `${durationText(minutes)} · ${transfers === 0 ? "direkt" : transfers === 1 ? "1 Umstieg" : `${transfers} Umstiege`}`;
    const body = legs.map((leg, index) => renderLeg(leg, legs[index + 1])).join("");
    return `<section class="hero">
<p class="eyebrow">${escape(day)}</p>
<h1>${escape(first.origin)} → ${escape(last.destination)}</h1>
<p class="summary">${hhmm(best(first.departure))} – ${hhmm(best(last.arrival))}${nextDay ? " (+1 Tag)" : ""} · ${escape(summary)}</p>
</section>
${body}`;
}

/// The page for a journey: the journey itself, the way into the app and the store link.
export function journeyPageHTML(id, view, { style, footer, appStoreURL }) {
    const first = view.legs[0];
    const last = view.legs[view.legs.length - 1];
    const route = `${first.origin} → ${last.destination}`;
    const store = appStoreURL
        ? `<a class="button secondary" href="${escape(appStoreURL)}">BetterBahn im App Store</a>` : "";
    return `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta name="theme-color" content="#f2f2f7" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
<meta property="og:title" content="${escape(route)}">
<meta property="og:description" content="${escape(`${dayFormat.format(new Date(first.departure.planned))} · ${hhmm(best(first.departure))} Uhr`)}">
<meta property="og:site_name" content="BetterBahn">
<title>${escape(route)} – BetterBahn</title>
${style}
<style>${JOURNEY_STYLE}</style>
</head>
<body>
<main>
<p class="brand">BetterBahn</p>
${renderJourney(view)}
<p class="meta">Stand: Zeitpunkt des Teilens.</p>
<div class="actions"><a class="button" href="betterbahn://share?id=${id}">In BetterBahn öffnen</a>${store}</div>
<footer class="foot">
<p>Mit BetterBahn auf dem iPhone siehst du die Reise live und kannst sie speichern.</p>
${footer}
</footer>
</main>
</body>
</html>
`;
}

// In the app's colors (`DesignSystem.swift`), like the arrival page.
const JOURNEY_STYLE = `
:root { --grouped: #f2f2f7; --card: #ffffff; --separator: rgba(60, 60, 67, .12); --fill: rgba(120, 120, 128, .13);
  --ontime: #219e59; --slight: #f28c0d; --heavy: #e02633; --long-distance: #1a1a1a; --brand: #db1730; --rail: #c7c7cc; }
@media (prefers-color-scheme: dark) { :root { --grouped: #000000; --card: #1c1c1e; --separator: rgba(84, 84, 88, .6);
  --fill: rgba(118, 118, 128, .24); --long-distance: #6b6b6b; --rail: #48484a; } }
body { background: var(--grouped); }
main { max-width: 34rem; padding: 1rem 1rem 3rem; }
.brand { margin: .25rem 0 1rem; font-weight: 700; font-size: .95rem; color: var(--brand); letter-spacing: -.01em; }
.hero { margin: 0 0 1rem; }
.hero h1 { font-size: 1.7rem; margin: .1rem 0 .4rem; letter-spacing: -.02em; }
.eyebrow { margin: 0; color: var(--muted); font-size: .85rem; font-weight: 600; }
.summary { margin: 0; font-weight: 600; font-variant-numeric: tabular-nums; }
.card { background: var(--card); border-radius: 22px; padding: 1.1rem 1.15rem; margin: 0;
  box-shadow: 0 4px 12px rgba(0, 0, 0, .06); border: .5px solid var(--separator); }
.card.cancelled .name { text-decoration: line-through; }
.train { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; margin: 0 0 .8rem; color: var(--muted); font-size: .9rem; }
.line { color: #fff; font-weight: 700; font-size: .8rem; padding: .2rem .55rem; border-radius: 999px; white-space: nowrap; }
.ends { display: grid; row-gap: .2rem; }
.end { display: grid; grid-template-columns: 4.6rem 1fr auto; align-items: baseline; column-gap: .5rem; }
.end .name { font-weight: 700; }
.t { font-variant-numeric: tabular-nums; font-weight: 600; }
.t.big { font-size: 1.15rem; font-weight: 700; }
.t s { color: var(--muted); font-weight: 400; font-size: .8em; text-decoration-thickness: 1px; display: block; }
.gl { color: var(--muted); font-size: .85rem; white-space: nowrap; font-variant-numeric: tabular-nums; }
.gl.moved { color: var(--heavy); font-weight: 600; }
.ontime { color: var(--ontime); } .slight { color: var(--slight); } .heavy { color: var(--heavy); }
.stops { margin: .3rem 0; }
.stops summary { cursor: pointer; color: var(--muted); font-size: .85rem; padding: .25rem 0; }
.stops ol { list-style: none; margin: .2rem 0; padding: 0; }
.stops li { display: grid; grid-template-columns: 4.6rem 1fr auto; align-items: baseline; column-gap: .5rem; font-size: .9rem; margin: .15rem 0; }
.stops li.cancelled .name { text-decoration: line-through; color: var(--muted); }
.stops li.through { color: var(--muted); }
.walk { text-align: center; color: var(--muted); font-size: .9rem; padding: .5rem 0; }
.transfer { text-align: center; color: var(--muted); font-size: .85rem; margin: .5rem 0; }
.transfer.tight { color: var(--slight); font-weight: 600; }
.pill { display: inline-block; font-size: .75rem; font-weight: 700; padding: .15rem .5rem; border-radius: 999px; margin: 0 0 .6rem; }
.pill.heavy { color: var(--heavy); background: rgba(224, 38, 51, .14); }
.note { background: rgba(242, 140, 13, .1); border-radius: 14px; padding: .6rem .8rem; margin: .8rem 0 0; font-size: .85rem; }
.meta { color: var(--muted); font-size: .8rem; text-align: center; margin: 1.2rem 0 1rem; }
.actions { display: flex; flex-direction: column; align-items: center; gap: .6rem; }
.button { display: inline-block; padding: .7rem 1.2rem; border-radius: 999px; background: var(--brand); color: #fff; text-decoration: none; font-weight: 600; }
.button.secondary { background: transparent; color: var(--brand); border: 1px solid var(--brand); }
.foot { color: var(--muted); font-size: .8rem; line-height: 1.45; text-align: center; margin-top: 1.4rem; }
.foot p { margin: .5rem 0; }
`;
