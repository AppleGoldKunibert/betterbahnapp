# App Store submission checklist

What App Store Connect needs besides the build, and notes for App Review. Keep this current when
features or data flows change (and update the privacy policy in `Cloudflare/worker.mjs` with it).

## Before submitting

- **bahn.de server** (`Server/bahnde-proxy`, game-server host behind Tailscale Funnel, `BahnDeProxy.baseURL`) running with the same `TOKEN_SECRET`.
- **Workers deployed** with `TOKEN_SECRET` (same value in `betterbahn2`, `betterbahn-pass` and
  `betterbahn-stats`, whose D1 database is set up as in `Cloudflare/stats/README.md`, and
  `betterbahn-push` with its APNs key, as in `Cloudflare/checkin-push/README.md`, and `betterbahn-live` with
  the same key and its D1 database, as in `Cloudflare/live-activity/README.md`),
  `DB_CLIENT_ID`/`DB_API_KEY` in `betterbahn2`, and `ALLOW_UNATTESTED` removed once no old builds
  are left. The privacy policy Worker (`betterbahn`) has the controller's name filled in, its KV
  namespace `SHARES` and `TOKEN_SECRET` set (share links), and the App ID has Associated Domains.
- **Privacy policy URL:** `https://betterbahn.betterbahn.workers.dev/datenschutz`.
- **Support URL:** `https://betterbahn.betterbahn.workers.dev/support`.
- **App Privacy:** nothing is collected in Apple's sense — data either stays on the device / in the
  user's iCloud, or is only passed through BetterBahn's Workers to answer the request right away
  (timetable lookups, Wallet pass signing) and not kept. Exception: a journey the user shares is
  stored for 30 days (connection only, no identity) so the short link works ("Ankunft teilen" adds the last
  train's stops and expires 2 h after the arrival) – decide whether to
  declare it (e.g. "Other User Content", not linked, not tracking). The train statistics
  (`Cloudflare/stats`, Settings → "Zugstatistik anzeigen", on by default) only ask that server for a
  train's figures by train number and stops, nothing is kept; the figures come from DB's open data
  (#336), the app reports nothing. Second exception: the user's Träwelling login (#452) is kept encrypted on
  `Cloudflare/checkin-push` while logged in (deleted on logout or after 180 days unused), and the check-in
  notifications (Settings → Träwelling → "Mitteilungen", off by default) keep the Träwelling user ID, the APNs
  device token and seen status and notification IDs until turned off – likely "Identifiers → User ID" and
  "Device ID", linked to the user, not tracking, purpose "App Functionality". Third exception: the
  Live Activity updates (`Cloudflare/live-activity`, Settings → Meine Reisen "Live-Aktivität über Server
  aktualisieren", on by default) keep the running journey (trains, stations, times, platforms) and the activity's
  push token from leaving the app until the arrival or reopening it – likely "Other User Content", not linked to
  the user, not tracking, purpose "App Functionality". Also: regular
  trips (#397, `/commutes` on `betterbahn-push`) keep the APNs device token with the day's trains, stations and
  planned times until shortly after arrival – "Device ID", not linked to an account, not tracking, "App
  Functionality".
  Check this against the current code before
  answering "Data Not Collected"; Träwelling check-ins go to the user's own Träwelling account at
  their request.
- **Demo access:** create a Träwelling test account and put its login in the review notes, and keep
  a cheap DB booking (order number + last name) whose ticket can be fetched, or say that the
  ticket features need a real DB booking.

## Review notes (paste into App Store Connect)

> BetterBahn is a private, non-commercial journey planner for trains in Germany. It is not
> affiliated with Deutsche Bahn AG (stated in Settings).
>
> Timetable data comes from Transitous (open data, transitous.org). Some details (coach sequences,
> extra stops, platforms) come from bahn.de's public web API through our own server.
>
> Träwelling (traewelling.de) is an optional, independent check-in service. Turn it on under
> Settings → Für Profis → Expertenmodus → Träwelling, then sign in with the demo account below.
>
> Tickets: "Ticket abrufen" opens bahn.de's own order search inside the app; the traveller's order
> number and last name go only to bahn.de and the ticket is stored only on the device. "Zu Apple
> Wallet hinzufügen" creates a Wallet pass that carries the ticket's original barcode unchanged; our
> server only signs passes whose barcode carries a valid signature of the ticket's issuer.
>
> Demo Träwelling account: [user] / [password]
> DB booking for ticket import: order number [ … ], last name [ … ]

## Open points from the review of 2026-10-01

- bahn.de, bahn.expert and bahn.jetzt are used without a written agreement (guideline 5.2.2); the
  proxy also sends browser user agents. Ask DB / the operators for permission if App Review asks.
- vagonweb.cz (planned Wagenreihung, train types) is used with the permission of vagonweb (issue #95);
  keep that email in case App Review asks. The app credits it ("Daten: vagonweb.cz").
- Attribution (#103): Settings → Datenquellen lists every service with links (Transitous sources,
  DB Timetables under CC BY 4.0, OpenStreetMap, OpenRailwayMap, bahn.de, vagonweb, bahn.expert,
  bahn.jetzt, Träwelling, zug.network for check-in emojis, Open-Meteo under CC BY 4.0 for the weather, #385, also credited in
  the weather popover); the map legend links OSM and OpenRailwayMap. All requests except the
  bahn.de proxy send `HTTPClient.identifyingUserAgent` (app version + `/support` contact).
- The share extension opens the app through the responder chain (`ShareViewController.openApp`),
  which Apple only officially allows for widgets. Common practice, but a possible review question.
- Zeitkarten from screenshots can be added to Wallet (see `TravelPassView`). The pass signer only
  signs them when the barcode's issuer signature verifies, so forged codes are refused; a genuine
  ticket of someone else still works (the Deutschland-Ticket is personal and checked with ID).
