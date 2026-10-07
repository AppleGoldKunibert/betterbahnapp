import { TOKEN_HEADER, unauthorized, verifyToken } from "./shared/appattest.mjs";

export default {
    async fetch(request, env) {
        return handlePage(request)
            ?? handleTraewellingCallback(request)
            ?? handleAppSiteAssociation(request, env)
            ?? await handleShare(request, env)
            ?? new Response("Not Found", { status: 404 });
    },
};

// MARK: - Pages (privacy policy and support, linked in the app's settings and in App Store Connect)

export const PRIVACY_PATH = "/datenschutz";
export const SUPPORT_PATH = "/support";

// null means the request is for a different route.
export function handlePage(request) {
    const url = new URL(request.url);
    const path = url.pathname.length > 1 ? url.pathname.replace(/\/$/, "") : url.pathname;
    const html = { [PRIVACY_PATH]: PRIVACY_HTML, [SUPPORT_PATH]: SUPPORT_HTML }[path];
    if (!html) return null;
    if (request.method !== "GET" && request.method !== "HEAD") {
        return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    return new Response(request.method === "HEAD" ? null : html, {
        status: 200,
        headers: {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "public, max-age=3600",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
        },
    });
}

const PAGE_STYLE = `<style>
:root { color-scheme: light dark; --text: #1d1d1f; --muted: #6e6e73; --bg: #ffffff; --accent: #c8102e; }
@media (prefers-color-scheme: dark) { :root { --text: #f5f5f7; --muted: #a1a1a6; --bg: #000000; --accent: #ff6b7f; } }
body { margin: 0; background: var(--bg); color: var(--text); font: 17px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { max-width: 42rem; margin: 0 auto; padding: 2rem 1rem 4rem; }
h1 { font-size: 2rem; line-height: 1.2; margin: 0 0 .25rem; }
h2 { font-size: 1.2rem; margin: 2rem 0 .5rem; }
p, li { margin: .5rem 0; }
.muted { color: var(--muted); }
a { color: var(--accent); }
</style>`;

export const PRIVACY_HTML = `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Datenschutz – BetterBahn</title>
${PAGE_STYLE}
</head>
<body>
<main>
<h1>Datenschutz</h1>
<p class="muted">BetterBahn für iPhone · Stand: 7. Oktober 2026</p>

<p>BetterBahn ist ein privates Projekt und steht in keiner Verbindung zur Deutschen Bahn AG. Die App hat
keine Benutzerkonten, keine Werbung, kein Tracking und keine Analyse-Werkzeuge. Was du in der App speicherst,
bleibt auf deinem Gerät oder in deinem eigenen iCloud-Konto.</p>

<h2>Verantwortlich</h2>
<p>Alfred Lach<br>E-Mail: <a href="mailto:goldkunibert@gmail.com">goldkunibert@gmail.com</a></p>

<h2>Auf deinem Gerät</h2>
<p>Gespeicherte Reisen, Favoriten, der Suchverlauf, Einstellungen sowie Tickets und Zeitkarten werden nur auf
deinem Gerät gespeichert. Tickets und Zeitkarten sind verschlüsselt, solange das Gerät gesperrt ist.
Wenn du die App löschst, sind diese Daten weg.</p>

<h2>iCloud</h2>
<p>Favoriten, Suchverlauf, gespeicherte Reisen und Einstellungen werden über den iCloud-Schlüssel-Wert-Speicher
mit deinen anderen Geräten abgeglichen, eine Träwelling-Anmeldung über den iCloud-Schlüsselbund. Das läuft
über dein Apple-Konto bei Apple; ich habe darauf keinen Zugriff. Tickets und Zeitkarten werden nicht über
iCloud abgeglichen.</p>

<h2>Fahrplandaten</h2>
<p>Für Suchen, Abfahrtstafeln und Echtzeitdaten schickt die App deine Anfragen (z. B. eingegebene Bahnhofsnamen,
Bahnhöfe, Zeiten und Zugnummern) an diese Dienste. Dabei sehen sie, wie bei jedem Abruf im Internet, die
IP-Adresse deines Geräts. Die App nennt sich dabei mit Name, Version und einer Kontaktadresse (User-Agent),
aber nicht mit Daten über dich:</p>
<ul>
<li><a href="https://transitous.org">Transitous</a> (Verbindungen, Abfahrten, Bahnhofssuche)</li>
<li><a href="https://www.vagonweb.cz">vagonweb.cz</a> (geplante Wagenreihungen und Zugtypen), <a href="https://bahn.expert">bahn.expert</a> (Zugtypen) und <a href="https://bahn.jetzt">bahn.jetzt</a> (Zugpositionen auf der Karte)</li>
<li><a href="https://www.openrailwaymap.org">OpenRailwayMap</a> (Kartenkacheln mit Daten von <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>) und Apple Karten</li>
<li>bahn.de und die Timetables-Schnittstelle der Deutschen Bahn – diese Anfragen laufen über den Server von
BetterBahn (siehe unten), daher sieht die Deutsche Bahn nicht deine IP-Adresse, sondern die des Servers.</li>
</ul>

<h2>Server von BetterBahn</h2>
<p>BetterBahn betreibt kleine Server-Funktionen bei Cloudflare, Inc. (Auftragsverarbeiter). Sie</p>
<ul>
<li>leiten Fahrplananfragen an bahn.de und die Timetables-Schnittstelle weiter und speichern die Antworten
kurz zwischen (Sekunden bis höchstens einen Tag), damit nicht jede Anfrage erneut gestellt wird,</li>
<li>signieren Apple-Wallet-Pässe: Wenn du „Zu Apple Wallet hinzufügen“ tippst, werden die Daten des Passes
(Barcode des Tickets, Namen der Reisenden, Verbindung, Sitzplätze, Auftragsnummer; bei Zeitkarten auch das
Geburtsdatum aus dem Barcode) an den Server geschickt, dort signiert und sofort zurückgegeben,</li>
<li>leiten die Anmeldung bei Träwelling an die App weiter,</li>
<li>speichern Reisen, die du teilst (siehe „Reisen teilen“),</li>
<li>sammeln Zugdaten für Statistiken (siehe „Zugstatistik“).</li>
</ul>
<p>Abgesehen von geteilten Reisen und den Zugdaten für die Statistik wird dabei nichts gespeichert oder protokolliert. Cloudflare verarbeitet zur Absicherung des Dienstes
IP-Adressen; Details stehen in der <a href="https://www.cloudflare.com/privacypolicy/">Datenschutzerklärung von Cloudflare</a>.</p>
<p>Damit nur die echte App diese Funktionen nutzen kann, prüft die App ihre Echtheit mit Apples App Attest.
Der Server erhält dabei eine zufällige Schlüsselkennung dieser App-Installation, aber keine Angaben über dich.</p>

<h2>Reisen teilen</h2>
<p>Wenn du eine Reise teilst, schickt die App die Verbindung (Bahnhöfe, Züge, Zeiten, Gleise) an den Server
von BetterBahn. Dort wird sie unter einer zufälligen Kennung 30 Tage lang gespeichert und danach automatisch
gelöscht. Geteilt wird nur ein kurzer Link; wer ihn hat, kann die Reise in dieser Zeit abrufen. Namen, Tickets
oder andere Angaben über dich sind nicht dabei. Ist der Server nicht erreichbar, teilt die App stattdessen einen
längeren Link, der die Reise selbst enthält; dann wird nichts gespeichert.</p>

<h2>Zugstatistik</h2>
<p>Solange „Zugdaten für Statistik teilen“ in den Einstellungen eingeschaltet ist (Standard), schickt die App
für Regional- und Fernzüge, die sie dir anzeigt (Abfahrtstafeln, Suchergebnisse, Zugverläufe), die Kennung
dieser Fahrt bei bahn.de an den Server von BetterBahn. Der Server fragt bei bahn.de den Verlauf dieser Fahrt
ab und speichert Fahrplan, Verspätungen, Gleise, Ausfälle, Störungsmeldungen und die Wagenreihung, um
Statistiken über Pünktlichkeit, Gleiswechsel und Fahrzeuge zu erstellen. Gespeichert wird nur, welcher Zug
wann wo gefahren ist, nicht wer ihn angesehen hat: keine Kennung deines Geräts oder deiner App-Installation,
kein Standort, nichts über dich. Die Zugdaten bleiben ein Jahr auf dem Server und werden danach gelöscht oder
offline archiviert.</p>

<h2>Tickets abrufen</h2>
<p>Zum Abrufen eines Tickets öffnet die App die Auftragssuche von bahn.de. Auftragsnummer und Nachname gehen nur
an bahn.de, das Ticket wird nur auf deinem Gerät gespeichert. Es gelten die
<a href="https://www.bahn.de/datenschutz">Datenschutzhinweise der Deutschen Bahn</a>.</p>

<h2>Standort</h2>
<p>Wenn du es erlaubst, nutzt die App deinen ungefähren Standort, um Bahnhöfe in deiner Nähe in der Suche
weiter oben anzuzeigen. Der Standort wird nur auf dem Gerät verwendet und nicht verschickt. Damit auch Bahnhöfe
in deiner Nähe gefunden werden, sucht die App zusätzlich mit den Namen naher Städte und Bahnhöfe (z.&nbsp;B.
„Berlin ost“ oder „Bernau“), die sie aus einer Liste auf dem Gerät nimmt; an Transitous gehen dabei nur diese
Namen mit dem Suchtext.</p>

<h2>Träwelling</h2>
<p>Wenn du dich bei <a href="https://traewelling.de">Träwelling</a> anmeldest, schickt die App deine Check-ins
(Zug, Strecke, Zeiten, Nachricht, Sichtbarkeit), deine Likes und Abfragen an Träwelling. Dafür gilt die
Datenschutzerklärung von Träwelling. Du kannst dich in den Einstellungen jederzeit abmelden.</p>
<p>Die App zeigt dir, wer von den Leuten, denen du auf Träwelling folgst, gerade eingecheckt ist. Um deren Zug
anzuzeigen, fragt sie Transitous nach den Abfahrten am Einstiegsbahnhof des Check-ins, mit Bahnhof und Uhrzeit,
aber ohne Namen; die Live-Position kommt wie bei deinen eigenen Zügen von bahn.jetzt.</p>
<p>Für die Emojis im Check-in-Text lädt die App die Emoji-Liste und -Bilder der Mastodon-Instanz, die mit
deinem Träwelling-Konto verbunden ist, sonst von <a href="https://zug.network">zug.network</a>. Dabei wird
nichts über dich gesendet außer deiner IP-Adresse, die jeder Abruf im Internet mitschickt.</p>

<h2>Mitteilungen</h2>
<p>Hinweise zu Verspätungen und Gleiswechseln erzeugt die App selbst auf deinem Gerät. Es gibt keine
Push-Mitteilungen über einen Server.</p>

<h2>Rechtsgrundlage und deine Rechte</h2>
<p>Die Verarbeitung dient dazu, die Funktionen bereitzustellen, die du in der App nutzt (Art. 6 Abs. 1 lit. b
DSGVO), den Dienst vor Missbrauch zu schützen und Statistiken über Züge zu erstellen (Art. 6 Abs. 1 lit. f
DSGVO). Die Zugstatistik kannst du in den Einstellungen jederzeit abschalten. Du hast das Recht auf Auskunft,
Berichtigung, Löschung, Einschränkung der Verarbeitung, Datenübertragbarkeit und Widerspruch sowie das Recht,
dich bei einer Datenschutz-Aufsichtsbehörde zu beschweren. Schreib mir dazu einfach eine E-Mail.</p>
</main>
</body>
</html>
`;

export const SUPPORT_HTML = `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hilfe – BetterBahn</title>
${PAGE_STYLE}
</head>
<body>
<main>
<h1>Hilfe &amp; Kontakt</h1>
<p class="muted">BetterBahn für iPhone</p>

<h2>Kontakt</h2>
<p>Fragen, Fehler oder Wünsche? Schreib mir an
<a href="mailto:goldkunibert@gmail.com">goldkunibert@gmail.com</a>. Bei Fehlern helfen Zug, Bahnhof und Uhrzeit.</p>

<h2>Warum fehlt die Wagenreihung?</h2>
<p>Die Deutsche Bahn veröffentlicht sie meist erst einige Stunden vor der Abfahrt, und nicht für jeden Zug.
Für Züge, die später fahren, zeigt BetterBahn den geplanten Zugtyp.</p>

<h2>Mein Ticket lässt sich nicht abrufen</h2>
<p>Du brauchst die Auftragsnummer (in der Buchungsbestätigung und unter dem Barcode) und den Nachnamen der
reisenden Person. Möchte bahn.de die Suche bestätigen, schließ das auf der angezeigten Seite ab.</p>

<h2>Wallet lehnt meinen Pass ab</h2>
<p>BetterBahn legt nur Barcodes in Apple Wallet, die eine gültige Signatur des Ausstellers tragen. Bei der
Kontrolle gilt immer das Ticket in der App, in der du es gekauft hast.</p>

<h2>Wie verbinde ich Träwelling?</h2>
<p>Einstellungen → Für Profis → Expertenmodus einschalten → Träwelling einschalten, dann
„Mit Träwelling anmelden“.</p>

<h2>Wie lösche ich meine Daten?</h2>
<p>Den Suchverlauf löschst du in den Einstellungen, gespeicherte Reisen, Favoriten und Tickets direkt in der App.
Wenn du die App löschst, sind auch alle Daten auf dem Gerät weg.</p>

<p class="muted"><a href="/datenschutz">Datenschutz</a> · BetterBahn ist ein privates Projekt und steht in keiner
Verbindung zur Deutschen Bahn AG.</p>
</main>
</body>
</html>
`;

// null means the request is for a different route.
export function handleTraewellingCallback(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/oauth/traewelling/callback") return null;

    const headers = {
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "Content-Type": "text/plain; charset=utf-8",
    };
    if (request.method !== "GET") {
        return new Response("Method not allowed", {
            status: 405,
            headers: { ...headers, Allow: "GET" },
        });
    }

    const parameters = url.searchParams;
    const allowed = ["code", "state", "error", "error_description", "error_uri"];
    const duplicated = allowed.some(name => parameters.getAll(name).length > 1);
    const code = parameters.get("code");
    const error = parameters.get("error");
    if (duplicated || !parameters.get("state") || Boolean(code) === Boolean(error)) {
        return new Response("Missing or invalid OAuth response. Start login in BetterBahn.", {
            status: 400,
            headers,
        });
    }

    // Fixed destination: never accept a user-supplied redirect target.
    // PKCE verification and state validation remain in the app.
    const callback = new URL("betterbahn://oauth");
    for (const name of allowed) {
        const value = parameters.get(name);
        if (value !== null) callback.searchParams.set(name, value);
    }
    return new Response(null, {
        status: 302,
        headers: { ...headers, Location: callback.href },
    });
}

// MARK: - Short share links (/s/<id>)

// A journey shared from the app is stored here for a while, so the app can share a short HTTPS link
// instead of a `betterbahn://share?data=…` link several KB long. The payload is exactly that link's
// `data` (zlib JSON, base64url); the app decodes and checks it as before, the Worker never looks inside.
//
// POST /share { data }  → 201 { id, url, expiresAt }   (App Attest token, rate limited per app install)
// GET  /share/<id>      → { data }                     (what the app fetches for a link)
// GET  /s/<id>          → fallback page: with the app installed, iOS opens the app instead (Universal Link)

export const SHARE_API_PATH = "/share";
export const SHARE_PAGE_PREFIX = "/s/";
export const SHARE_TTL = 30 * 24 * 60 * 60;
// Same cap as `JourneyShareLink.maxEncodedLength` in the app.
export const MAX_SHARE_DATA_LENGTH = 64 * 1024;
export const SHARE_ID_LENGTH = 8;
const ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const ID_PATTERN = /^[A-Za-z0-9]{8}$/;
const DATA_PATTERN = /^[A-Za-z0-9_-]+$/;
export const DEFAULT_APP_IDS = "9NXP66M9UL.de.goldkunibert.BetterBahn";

// null means the request is for a different route.
export function handleAppSiteAssociation(request, env = {}) {
    const url = new URL(request.url);
    if (url.pathname !== "/.well-known/apple-app-site-association") return null;
    const appIDs = (env.APP_IDS || DEFAULT_APP_IDS).split(",").map(id => id.trim()).filter(Boolean);
    const body = {
        applinks: {
            details: [{ appIDs, components: [{ "/": `${SHARE_PAGE_PREFIX}*`, comment: "Geteilte Reisen" }] }],
        },
    };
    return new Response(JSON.stringify(body), {
        status: 200,
        headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=3600" },
    });
}

// null means the request is for a different route. `now` only matters for the returned expiry.
export async function handleShare(request, env = {}, now = Date.now()) {
    const url = new URL(request.url);
    if (url.pathname === SHARE_API_PATH) return createShare(request, env, url, now);
    if (url.pathname.startsWith(`${SHARE_API_PATH}/`)) {
        return readShare(request, env, url.pathname.slice(SHARE_API_PATH.length + 1));
    }
    if (url.pathname.startsWith(SHARE_PAGE_PREFIX)) {
        return sharePage(request, env, url.pathname.slice(SHARE_PAGE_PREFIX.length).replace(/\/$/, ""));
    }
    return null;
}

async function createShare(request, env, url, now) {
    if (request.method !== "POST") return shareJSON(405, { error: "method_not_allowed" }, { Allow: "POST" });
    if (!env.SHARES) return shareJSON(503, { error: "not_configured" });

    // Only the genuine app may store journeys: an App Attest token from the bahn.de proxy's `/auth`
    // routes (same TOKEN_SECRET), or no token while ALLOW_UNATTESTED is "true" (see shared/appattest.mjs).
    const token = request.headers.get(TOKEN_HEADER);
    const claims = token && env.TOKEN_SECRET ? await verifyToken(token, "a", env.TOKEN_SECRET) : null;
    if (token ? !claims : env.ALLOW_UNATTESTED !== "true") return unauthorized();
    if (!(await withinLimit(env.SHARE_CREATE_LIMITER, claims?.kid ?? clientIP(request)))) {
        return shareJSON(429, { error: "rate_limited" });
    }

    const body = await request.arrayBuffer();
    if (body.byteLength > MAX_SHARE_DATA_LENGTH + 1024) return shareJSON(413, { error: "too_large" });
    let data;
    try {
        data = JSON.parse(new TextDecoder().decode(body))?.data;
    } catch {
        return shareJSON(400, { error: "invalid_json" });
    }
    if (typeof data !== "string" || !DATA_PATTERN.test(data)) return shareJSON(400, { error: "invalid_data" });
    if (data.length > MAX_SHARE_DATA_LENGTH) return shareJSON(413, { error: "too_large" });

    // No "is this ID free?" read first: KV caches a miss for up to a minute at that location, so the
    // link would 404 right after sharing. With 62^8 IDs a collision is practically impossible.
    const id = randomID();
    await env.SHARES.put(id, data, { expirationTtl: SHARE_TTL });
    return shareJSON(201, {
        id,
        url: `${url.origin}${SHARE_PAGE_PREFIX}${id}`,
        expiresAt: new Date(now + SHARE_TTL * 1000).toISOString(),
    });
}

async function readShare(request, env, id) {
    if (request.method !== "GET") return shareJSON(405, { error: "method_not_allowed" }, { Allow: "GET" });
    if (!env.SHARES) return shareJSON(503, { error: "not_configured" });
    if (!ID_PATTERN.test(id)) return shareJSON(404, { error: "not_found" });
    if (!(await withinLimit(env.SHARE_READ_LIMITER, clientIP(request)))) return shareJSON(429, { error: "rate_limited" });
    const data = await env.SHARES.get(id);
    if (data === null) return shareJSON(404, { error: "not_found" });
    return shareJSON(200, { data });
}

async function sharePage(request, env, id) {
    if (request.method !== "GET" && request.method !== "HEAD") {
        return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    let exists = false;
    if (ID_PATTERN.test(id) && env.SHARES) {
        if (!(await withinLimit(env.SHARE_READ_LIMITER, clientIP(request)))) {
            return new Response("Too many requests", { status: 429 });
        }
        exists = await env.SHARES.get(id) !== null;
    }
    const html = sharePageHTML(exists ? id : null, env.APP_STORE_URL);
    return new Response(request.method === "HEAD" ? null : html, {
        status: exists ? 200 : 404,
        headers: {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
        },
    });
}

/// Rate limiting binding (`[[ratelimits]]` in wrangler.toml); without one, nothing is limited.
async function withinLimit(limiter, key) {
    if (!limiter) return true;
    const { success } = await limiter.limit({ key: String(key) });
    return success;
}

function clientIP(request) {
    return request.headers.get("CF-Connecting-IP") ?? "unknown";
}

export function randomID() {
    // 248 is the largest multiple of 62 below 256: rejecting bytes above keeps every character equally likely.
    let id = "";
    while (id.length < SHARE_ID_LENGTH) {
        for (const byte of crypto.getRandomValues(new Uint8Array(16))) {
            if (byte < 248 && id.length < SHARE_ID_LENGTH) id += ID_ALPHABET[byte % 62];
        }
    }
    return id;
}

function shareJSON(status, body, extra = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
    });
}

function escapeHTML(text) {
    return String(text).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

/// `id` is null when the link is unknown or has expired.
export function sharePageHTML(id, appStoreURL) {
    const store = appStoreURL
        ? `<p><a class="button secondary" href="${escapeHTML(appStoreURL)}">BetterBahn im App Store</a></p>`
        : "";
    const content = id
        ? `<h1>Geteilte Reise</h1>
<p>Jemand hat dir eine Reise aus BetterBahn geschickt. Öffne den Link auf einem iPhone mit BetterBahn, dann
erscheint die Reise direkt in der App.</p>
<p><a class="button" href="betterbahn://share?id=${id}">In BetterBahn öffnen</a></p>
${store}`
        : `<h1>Link abgelaufen</h1>
<p>Diese Reise ist nicht mehr gespeichert. Geteilte Reisen bleiben ${SHARE_TTL / 86400} Tage abrufbar. Bitte
lass sie dir noch einmal schicken.</p>
${store}`;
    return `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta property="og:title" content="Reise in BetterBahn">
<meta property="og:site_name" content="BetterBahn">
<title>Geteilte Reise – BetterBahn</title>
${PAGE_STYLE}
<style>
.button { display: inline-block; padding: .7rem 1.2rem; border-radius: 999px; background: var(--accent); color: #fff; text-decoration: none; font-weight: 600; }
.button.secondary { background: transparent; color: var(--accent); border: 1px solid var(--accent); }
</style>
</head>
<body>
<main>
${content}
<p class="muted"><a href="${PRIVACY_PATH}">Datenschutz</a> · BetterBahn ist ein privates Projekt und steht in keiner
Verbindung zur Deutschen Bahn AG.</p>
</main>
</body>
</html>
`;
}
