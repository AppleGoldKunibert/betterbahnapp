# App Store submission checklist

What App Store Connect needs besides the build, and notes for App Review. Keep this current when
features or data flows change (and update the privacy policy in `Cloudflare/worker.mjs` with it).

## Before submitting

- **Workers deployed** with `TOKEN_SECRET` (same value in `betterbahn2` and `betterbahn-pass`),
  `DB_CLIENT_ID`/`DB_API_KEY` in `betterbahn2`, and `ALLOW_UNATTESTED` removed once no old builds
  are left. The privacy policy Worker (`betterbahn`) has the controller's name filled in.
- **Privacy policy URL:** `https://betterbahn.kunibert88.workers.dev/datenschutz`.
- **App Privacy:** nothing is collected in Apple's sense — data either stays on the device / in the
  user's iCloud, or is only passed through BetterBahn's Workers to answer the request right away
  (timetable lookups, Wallet pass signing) and not kept. Check this against the current code before
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
> Wallet hinzufügen" creates a Wallet pass that carries the ticket's original barcode unchanged.
>
> Demo Träwelling account: [user] / [password]
> DB booking for ticket import: order number [ … ], last name [ … ]

## Open points from the review of 2026-10-01

- bahn.de, bahn.expert and bahn.jetzt are used without a written agreement (guideline 5.2.2); the
  proxy also sends browser user agents. Ask DB / the operators for permission if App Review asks.
- The share extension opens the app through the responder chain (`ShareViewController.openApp`),
  which Apple only officially allows for widgets. Common practice, but a possible review question.
- Zeitkarten from screenshots can be added to Wallet (see `TravelPassView`).
