// "Ankunft teilen" (#317): a share link for the person picking you up. Besides the journey for the app, the
// app sends the last train (`arrival`: its stops from boarding to getting off, see `ArrivalShare` in the app);
// `/s/<id>` then shows a small page with the arrival time, delay, platform and the remaining stops, which
// asks `/share/<id>/live` every 30 seconds. Live times come from bahn.de's journey details (by the train's
// journey ID, cached 30 s, so many viewers make one request); without them the page shows what the app sent.
// The link only works until 2 hours after the arrival.

import { upstreamHeaders } from "./bahnde-proxy/worker.mjs";
import { berlinToUnix, parseJourney } from "./stats/worker.mjs";

export const AFTER_ARRIVAL = 2 * 3600;
// A late train keeps its link longer, but never past this after the planned arrival.
const MAX_LATE = 12 * 3600;
export const LIVE_TTL = 30;
const LIVE_TIMEOUT = 5000;
const MAX_STOPS = 150;
const BAHN_DE = "https://www.bahn.de/web/api/";
const JOURNEY_ID_PATTERN = /^\d+\|#[\x20-\x7eÀ-ſ]+$/;
const EVA_PATTERN = /^\d{6,9}$/;
const PRODUCTS = new Set(["highSpeed", "longDistance", "nightTrain", "interregio", "regionalExpress", "regional",
    "suburban", "subway", "tram", "bus", "coach", "ferry", "other"]);

// MARK: - What the app sends

/// The arrival the app sent, checked and with times as Unix milliseconds; null when it isn't one.
export function parseArrival(input) {
    if (!input || typeof input !== "object") return null;
    const train = text(input.train, 40);
    const product = PRODUCTS.has(input.product) ? input.product : "other";
    const color = Number.isInteger(input.color) && input.color >= 0 && input.color <= 0xffffff ? input.color : null;
    const journeyId = typeof input.journeyId === "string" && input.journeyId.length <= 500 && JOURNEY_ID_PATTERN.test(input.journeyId)
        ? input.journeyId : null;
    if (!train || !Array.isArray(input.stops) || input.stops.length < 2 || input.stops.length > MAX_STOPS) return null;
    const stops = input.stops.map(parseStop);
    if (stops.some(stop => !stop) || !stops[stops.length - 1].arr) return null;
    return { train, product, color, journeyId, stops };
}

function parseStop(stop) {
    if (!stop || typeof stop !== "object") return null;
    const name = text(stop.name, 120);
    const times = ["arrival", "arrivalLive", "departure", "departureLive"].map(key => time(stop[key]));
    if (!name || times.includes(undefined)) return null;
    const [arr, arrRt, dep, depRt] = times;
    return {
        name,
        eva: typeof stop.eva === "string" && EVA_PATTERN.test(stop.eva) ? stop.eva : null,
        arr, arrRt, dep, depRt,
        platform: text(stop.platform, 12),
        platformRt: text(stop.platformLive, 12),
        cancelled: stop.cancelled === true,
    };
}

function text(value, max) {
    return typeof value === "string" && value.trim() && value.length <= max ? value.trim() : null;
}

/// Unix milliseconds of an ISO date; null when missing, undefined when malformed.
function time(value) {
    if (value === undefined || value === null) return null;
    const ms = typeof value === "string" ? Date.parse(value) : NaN;
    return Number.isFinite(ms) ? ms : undefined;
}

/// When the link stops working: 2 hours after the (expected) arrival.
export function expiryOf(stops) {
    const last = stops[stops.length - 1];
    return Math.max(last.arr, last.arrRt ?? 0) + AFTER_ARRIVAL * 1000;
}

/// A later expiry for a train that is now expected later than when the link was made; null otherwise.
export function extendedExpiry(entry, view) {
    const last = entry.arrival.stops[entry.arrival.stops.length - 1];
    const expiry = Math.min(expiryOf(view.stops), last.arr + MAX_LATE * 1000);
    return expiry > entry.expiresAt ? expiry : null;
}

// MARK: - Live data

/// What the page shows: the stored arrival, with bahn.de's live times where it has the train.
export async function arrivalView(arrival, expiresAt, deps = {}) {
    const now = deps.now ?? Date.now();
    let stops = arrival.stops;
    let live = false;
    let messages = [];
    if (arrival.journeyId) {
        try {
            const details = await journeyDetails(arrival.journeyId, deps);
            const run = details ? parseJourney(details, arrival.journeyId) : null;
            const section = run ? liveSection(run.stops, arrival.stops) : null;
            if (section) {
                stops = section;
                live = true;
                messages = run.messages.slice(0, 2);
            }
        } catch {
            // bahn.de blocked or down: the page shows the app's times until the next refresh.
        }
    }
    return { train: arrival.train, product: arrival.product, color: arrival.color, live, stops, messages, updatedAt: now, expiresAt };
}

async function journeyDetails(journeyId, { fetchUpstream = fetch, cache = null, waitUntil } = {}) {
    const url = `${BAHN_DE}reiseloesung/fahrt?journeyId=${encodeURIComponent(journeyId)}&poly=false`;
    const key = new Request(url);
    const cached = cache ? await cache.match(key) : null;
    if (cached) return cached.json();
    const response = await fetchUpstream(url, { headers: upstreamHeaders(), signal: AbortSignal.timeout(LIVE_TIMEOUT) });
    if (response.status === 404 || response.status === 400) return null;
    if (!response.ok) throw new Error(`bahn.de ${response.status}`);
    const body = await response.text();
    if (cache) {
        const store = cache.put(key, new Response(body, { headers: { "Cache-Control": `public, max-age=${LIVE_TTL}` } }));
        waitUntil ? waitUntil(store) : await store;
    }
    return JSON.parse(body);
}

/// bahn.de's stops from where the user boards to where they get off, null when bahn.de's train doesn't
/// have both (another run, or a station under another name).
export function liveSection(liveStops, shared) {
    const first = shared[0];
    const last = shared[shared.length - 1];
    const start = liveStops.findIndex(stop => sameStation(stop, first));
    if (start < 0) return null;
    const end = liveStops.findIndex((stop, index) => index > start && sameStation(stop, last));
    if (end < 0) return null;
    return liveStops.slice(start, end + 1).map(stop => ({
        name: stop.name,
        eva: stop.eva,
        arr: unix(stop.arr), arrRt: unix(stop.arrRt),
        dep: unix(stop.dep), depRt: unix(stop.depRt),
        platform: stop.platform || null,
        platformRt: stop.platformRt || null,
        cancelled: stop.cancelled,
    }));
}

function sameStation(liveStop, sharedStop) {
    if (sharedStop.eva && liveStop.eva) return liveStop.eva === sharedStop.eva;
    return normalized(liveStop.name) === normalized(sharedStop.name);
}

function normalized(name) {
    return (name ?? "").toLowerCase().normalize("NFD").replace(/[^a-z0-9]/g, "");
}

function unix(local) {
    return local ? berlinToUnix(local) * 1000 : null;
}

// MARK: - Page

/// The page's content for `view` at `now`. Runs on the Worker for the first answer and in the browser
/// (as its source text) for every refresh, so it must not use anything from outside its own body.
export function renderArrival(view, now) {
    const escape = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
    const clock = new Intl.DateTimeFormat("de-DE", { timeZone: "Europe/Berlin", hour: "2-digit", minute: "2-digit" });
    const hhmm = ms => clock.format(new Date(ms));
    const delayOf = (planned, actual) => planned && actual ? Math.round((actual - planned) / 60000) : null;
    const tone = minutes => minutes === null ? "" : minutes > 10 ? "heavy" : minutes > 5 ? "slight" : "ontime";
    const productColors = {
        regionalExpress: "#db1730", regional: "#db1730", suburban: "#1a994d", subway: "#1f61cc", tram: "#cc731a",
        bus: "#8547bd", coach: "#8547bd", ferry: "#1a8ccc", other: "#8e8e93",
    };
    const lineColor = view.color !== null && view.color !== undefined
        ? `#${view.color.toString(16).padStart(6, "0")}` : productColors[view.product] ?? "var(--long-distance)";
    const duration = minutes => minutes < 60 ? `${minutes} Min.`
        : `${Math.floor(minutes / 60)} Std.${minutes % 60 ? ` ${minutes % 60} Min.` : ""}`;

    const stops = view.stops;
    const origin = stops[0];
    const destination = stops[stops.length - 1];
    const arrival = destination.arrRt ?? destination.arr;
    const delay = view.live ? delayOf(destination.arr, destination.arrRt) : null;
    const departure = origin.depRt ?? origin.dep;
    const leaves = stop => stop.depRt ?? stop.dep ?? stop.arrRt ?? stop.arr;
    const reached = stop => stop === destination ? arrival <= now : leaves(stop) <= now;

    let status;
    if (destination.cancelled) status = `<span class="pill heavy">Fällt aus</span> Der Zug hält nicht in ${escape(destination.name)}.`;
    else if (arrival <= now) status = "Angekommen";
    else if (departure && departure > now) status = `Fährt um ${hhmm(departure)} in ${escape(origin.name)} ab`;
    else status = `Ankunft in ${duration(Math.max(1, Math.round((arrival - now) / 60000)))}`;
    const pill = destination.cancelled || delay === null ? ""
        : `<span class="pill ${tone(delay)}">${delay > 0 ? `+${delay} min` : "pünktlich"}</span>`;

    const platform = destination.platformRt ?? destination.platform;
    const platformChanged = destination.platformRt && destination.platform && destination.platformRt !== destination.platform;
    const platformBadge = platform
        ? `<div class="platform${platformChanged ? " changed" : ""}"><span>Gleis</span><strong>${escape(platform)}</strong></div>`
            + (platformChanged ? `<p class="platform-note">statt ${escape(destination.platform)}</p>` : "")
        : "";

    const nextIndex = stops.findIndex(stop => !reached(stop));
    const rows = stops.map((stop, index) => {
        const isLast = index === stops.length - 1;
        const planned = isLast ? stop.arr : stop.dep ?? stop.arr;
        const actual = isLast ? stop.arrRt : stop.depRt ?? stop.arrRt;
        const stopDelay = view.live ? delayOf(planned, actual) : null;
        const live = stop.cancelled ? `<span class="live heavy">Ausfall</span>`
            : stopDelay !== null && stopDelay !== 0 ? `<span class="live ${tone(stopDelay)}">${hhmm(actual)}</span>` : "";
        const stopPlatform = stop.platformRt ?? stop.platform;
        const moved = stop.platformRt && stop.platform && stop.platformRt !== stop.platform;
        const state = index === nextIndex ? "next" : reached(stop) ? "passed" : "";
        return `<li class="${state}${isLast ? " last" : ""}${stop.cancelled ? " cancelled" : ""}">
<span class="times"><span class="${stopDelay === 0 ? "ontime" : ""}">${planned ? hhmm(planned) : ""}</span>${live}</span>
<span class="dot"></span>
<span class="name">${escape(stop.name)}</span>
<span class="gl${moved ? " moved" : ""}">${stopPlatform ? `Gl. ${escape(stopPlatform)}` : ""}</span>
</li>`;
    }).join("");

    const messages = (view.messages ?? []).map(message => `<p>${escape(message)}</p>`).join("");
    const source = view.live ? "Live-Daten der Deutschen Bahn" : "Fahrplanzeiten, gerade ohne Live-Daten";

    return `<section class="card hero">
<p class="eyebrow">Ankunft in</p>
<h1>${escape(destination.name)}</h1>
<p class="train"><span class="line" style="background:${lineColor}">${escape(view.train)}</span><span>von ${escape(origin.name)}</span></p>
<div class="arrival">
<div><span class="time ${destination.cancelled ? "struck" : delay === 0 ? "ontime" : delay !== null ? tone(delay) : ""}">${hhmm(arrival)}</span>${delay ? `<span class="planned">${hhmm(destination.arr)}</span>` : ""}</div>
<div class="platform-box">${platformBadge}</div>
</div>
<p class="status">${pill}<span>${status}</span></p>
</section>
${messages ? `<section class="note">${messages}</section>` : ""}
<section class="card">
<h2>Halte</h2>
<ol class="stops" style="--line:${lineColor}">${rows}</ol>
</section>
<p class="meta">${source} · Stand ${hhmm(view.updatedAt)}</p>`;
}

/// The whole page; the browser re-renders it from `/share/<id>/live` every 30 seconds.
export function arrivalPageHTML(id, view, nonce, { style, footer }) {
    const destination = view.stops[view.stops.length - 1].name;
    const escape = value => String(value).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
    // `<` escaped so nothing in the data can end the script.
    const json = JSON.stringify(view).replace(/</g, "\\u003c");
    return `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta name="theme-color" content="#f2f2f7" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
<meta property="og:title" content="Ankunft in ${escape(destination)}">
<meta property="og:description" content="${escape(view.train)} · Ankunftszeit und Gleis, live">
<meta property="og:site_name" content="BetterBahn">
<title>Ankunft in ${escape(destination)} – BetterBahn</title>
${style}
<style>${ARRIVAL_STYLE}</style>
</head>
<body class="grouped">
<main>
<p class="brand">BetterBahn</p>
<div id="arrival">${renderArrival(view, view.updatedAt)}</div>
<footer class="foot">
<p>Der Link funktioniert bis 2 Stunden nach der Ankunft. Mit BetterBahn auf dem iPhone:
<a href="betterbahn://share?id=${id}">in der App öffnen</a>.</p>
${footer}
</footer>
</main>
<script nonce="${nonce}">
(() => {
    const render = ${renderArrival.toString()};
    const box = document.getElementById("arrival");
    let view = ${json};
    const draw = () => { box.innerHTML = render(view, Date.now()); };
    async function refresh() {
        if (document.hidden || Date.now() > view.expiresAt) return;
        try {
            const response = await fetch("/share/${id}/live", { cache: "no-store" });
            if (response.status === 404) return location.reload();
            if (response.ok) view = await response.json();
        } catch {}
        draw();
    }
    draw();
    setInterval(refresh, ${LIVE_TTL * 1000});
    document.addEventListener("visibilitychange", refresh);
})();
</script>
</body>
</html>
`;
}

// In the app's colors (`DesignSystem.swift`): grouped background, white cards, the delay colors, the platform badge.
const ARRIVAL_STYLE = `
:root { --grouped: #f2f2f7; --card: #ffffff; --separator: rgba(60, 60, 67, .12); --fill: rgba(120, 120, 128, .13);
  --ontime: #219e59; --slight: #f28c0d; --heavy: #e02633; --long-distance: #1a1a1a; --brand: #db1730; }
@media (prefers-color-scheme: dark) { :root { --grouped: #000000; --card: #1c1c1e; --separator: rgba(84, 84, 88, .6);
  --fill: rgba(118, 118, 128, .24); --long-distance: #6b6b6b; } }
body.grouped { background: var(--grouped); }
main { max-width: 34rem; padding: 1rem 1rem 3rem; }
.brand { margin: .25rem 0 1rem; font-weight: 700; font-size: .95rem; color: var(--brand); letter-spacing: -.01em; }
.card { background: var(--card); border-radius: 22px; padding: 1.1rem 1.15rem; margin: 0 0 .9rem;
  box-shadow: 0 4px 12px rgba(0, 0, 0, .06); border: .5px solid var(--separator); }
.hero h1 { font-size: 1.85rem; margin: 0 0 .55rem; letter-spacing: -.02em; }
.eyebrow { margin: 0; color: var(--muted); font-size: .85rem; font-weight: 600; }
.train { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; margin: 0; color: var(--muted); font-size: .95rem; }
.line { color: #fff; font-weight: 700; font-size: .8rem; padding: .2rem .55rem; border-radius: 999px; white-space: nowrap; }
.arrival { display: flex; align-items: center; justify-content: space-between; gap: 1rem; margin: 1.1rem 0 .4rem; }
.time { font-size: 3rem; font-weight: 700; line-height: 1; letter-spacing: -.03em; font-variant-numeric: tabular-nums; }
.time.struck { text-decoration: line-through; text-decoration-color: var(--heavy); color: var(--muted); }
.planned { margin-left: .6rem; color: var(--muted); text-decoration: line-through; font-size: 1.1rem; font-variant-numeric: tabular-nums; }
.platform-box { text-align: center; }
.platform { display: inline-flex; flex-direction: column; align-items: center; min-width: 58px; padding: .3rem .4rem;
  border-radius: 10px; background: var(--fill); }
.platform span { font-size: .55rem; font-weight: 600; text-transform: uppercase; opacity: .8; }
.platform strong { font-size: 1.45rem; line-height: 1.1; font-variant-numeric: tabular-nums; }
.platform.changed { background: var(--heavy); color: #fff; }
.platform-note { margin: .25rem 0 0; font-size: .75rem; font-weight: 600; color: var(--heavy); }
.status { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; margin: .6rem 0 0; font-weight: 600; }
.pill { font-size: .75rem; font-weight: 700; padding: .15rem .5rem; border-radius: 999px; }
.pill.ontime { color: var(--ontime); background: rgba(33, 158, 89, .14); }
.pill.slight { color: var(--slight); background: rgba(242, 140, 13, .14); }
.pill.heavy { color: var(--heavy); background: rgba(224, 38, 51, .14); }
.ontime { color: var(--ontime); } .slight { color: var(--slight); } .heavy { color: var(--heavy); }
.note { background: rgba(242, 140, 13, .1); border-radius: 14px; padding: .7rem .9rem; margin: 0 0 .9rem; font-size: .9rem; }
.note p { margin: .2rem 0; }
.card h2 { font-size: 1.05rem; margin: 0 0 .6rem; }
.stops { list-style: none; margin: 0; padding: 0; }
.stops li { display: grid; grid-template-columns: 3.4rem 1.2rem 1fr auto; align-items: start; column-gap: .45rem;
  position: relative; padding: .45rem 0; }
.stops li:not(.last)::after { content: ""; position: absolute; left: calc(3.4rem + .45rem + .6rem - 1.5px); top: 1.05rem; bottom: -1.05rem;
  width: 3px; background: var(--fill); }
.stops li.passed:not(.last)::after { background: var(--line); }
.times { display: flex; flex-direction: column; font-variant-numeric: tabular-nums; font-weight: 600; }
.live { font-size: .8rem; }
.dot { width: 11px; height: 11px; margin: .25rem auto 0; border-radius: 50%; border: 2.5px solid var(--line);
  background: var(--card); position: relative; z-index: 1; }
.passed .dot { background: var(--line); }
.next .dot { box-shadow: 0 0 0 4px var(--fill); }
.passed .name, .passed .times { color: var(--muted); }
.last .name { font-weight: 700; }
.cancelled .name { text-decoration: line-through; color: var(--muted); }
.gl { margin-top: .12rem; color: var(--muted); font-size: .85rem; white-space: nowrap; font-variant-numeric: tabular-nums; }
.gl.moved { color: var(--heavy); font-weight: 600; }
.meta { color: var(--muted); font-size: .8rem; text-align: center; margin: .2rem 0 1.4rem; }
.foot { color: var(--muted); font-size: .8rem; line-height: 1.45; text-align: center; }
.foot p { margin: .5rem 0; }
`;
