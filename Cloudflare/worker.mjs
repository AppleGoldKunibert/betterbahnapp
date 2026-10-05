export default {
    async fetch(request) {
        return handlePage(request)
            ?? handleTraewellingCallback(request)
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
<p class="muted">BetterBahn für iPhone · Stand: 1. Oktober 2026</p>

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
IP-Adresse deines Geräts:</p>
<ul>
<li><a href="https://transitous.org">Transitous</a> (Verbindungen, Abfahrten, Bahnhofssuche)</li>
<li><a href="https://bahn.expert">bahn.expert</a> (Zugtypen) und <a href="https://bahn.jetzt">bahn.jetzt</a> (Zugpositionen auf der Karte)</li>
<li><a href="https://www.openrailwaymap.org">OpenRailwayMap</a> (Kartenkacheln) und Apple Karten</li>
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
<li>leiten die Anmeldung bei Träwelling an die App weiter.</li>
</ul>
<p>Dabei wird nichts gespeichert oder protokolliert. Cloudflare verarbeitet zur Absicherung des Dienstes
IP-Adressen; Details stehen in der <a href="https://www.cloudflare.com/privacypolicy/">Datenschutzerklärung von Cloudflare</a>.</p>
<p>Damit nur die echte App diese Funktionen nutzen kann, prüft die App ihre Echtheit mit Apples App Attest.
Der Server erhält dabei eine zufällige Schlüsselkennung dieser App-Installation, aber keine Angaben über dich.</p>

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
(Zug, Strecke, Zeiten, Nachricht, Sichtbarkeit) und Abfragen an Träwelling. Dafür gilt die Datenschutzerklärung
von Träwelling. Du kannst dich in den Einstellungen jederzeit abmelden.</p>

<h2>Mitteilungen</h2>
<p>Hinweise zu Verspätungen und Gleiswechseln erzeugt die App selbst auf deinem Gerät. Es gibt keine
Push-Mitteilungen über einen Server.</p>

<h2>Rechtsgrundlage und deine Rechte</h2>
<p>Die Verarbeitung dient dazu, die Funktionen bereitzustellen, die du in der App nutzt (Art. 6 Abs. 1 lit. b
DSGVO), und den Dienst vor Missbrauch zu schützen (Art. 6 Abs. 1 lit. f DSGVO). Du hast das Recht auf Auskunft,
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
