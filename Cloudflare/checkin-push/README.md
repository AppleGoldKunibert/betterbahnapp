# Check-in notifications (`betterbahn-push`)

Push notifications for new check-ins of the people a Träwelling user follows (#266) and about the
user's own check-ins (#447: likes, people checking in on the same train), Settings → Träwelling →
"Mitteilungen". iOS decides on its own when an app may look in the
background, often hours later, so the app doesn't look itself; this Worker does.

1. Turning the first of them on sends the app's login (`loginId`, `loginSecret`, see below), its APNs
   device token, the Träwelling user ID and `kinds` (`followed`, `likes`, `companions`; missing means
   `followed`) to `POST /subscriptions` (App Attest token) and gets `{ id, secret }` back. Likes and
   fellow travellers need a login with `read-notifications`; one handed over from before #452 signs in
   again first. Before #452 the app signed in a second time for this Worker (`code`, `codeVerifier` in
   place of the login); those sign-ups keep that login of their own until the app moves them over.
2. Every minute the cron trigger looks at the subscriptions due in that minute (each one every
   `INTERVAL_MINUTES`, default 2): it renews the login when it expired. For `followed` it loads the
   dashboard (first page) and sends an APNs notification for each check-in of someone else that is new
   and under way or leaving within 20 minutes (the app's rule). For `likes` and `companions` it loads
   Träwelling's notifications (first page) and sends one for each new `StatusLiked` ("Anna gefällt dein
   Check-in", `ownStatusID`) and `UserJoinedConnection` ("Bob fährt mit dir", `companionStatusID`; it
   replaces a followed push about the same check-in). The first look only remembers what is there
   already; a kind turned on again starts over.
   Likes and fellow travellers also come right away through Träwelling's webhook (below); the look every
   2 minutes stays as the fallback and skips what the webhook already reported.
3. `PUT /subscriptions/<id> { secret, deviceToken, sandbox, kinds }` keeps the device token and kinds
   current (the app sends them on every start and when a setting changes); `DELETE /subscriptions/<id>
   { secret }` (all settings off, Träwelling logout) deletes the row and ends the Worker's Träwelling login.

When Träwelling ends the login or APNs says the app is gone, the row is deleted; the app then gets a
404 and turns the setting off. Stored per device: device token, Träwelling user ID, the login (or its
ID), the kinds and the IDs of the check-ins and notifications already seen. No location, no names.

## The app's Träwelling login (`/logins`, #452)

Träwelling's access tokens last an hour, refresh tokens 30 days, and each refresh token works once. A
device renewing its own login lost it when the answer didn't arrive (poor reception) or after 30 days
without opening the app. So this Worker keeps the only login per user and is the only one renewing it
(`logins.mjs`, table `logins`, AES-GCM with `TOKEN_KEY`):

- `POST /logins { code, codeVerifier }` exchanges the authorization code (the app's scopes, with
  `read-notifications`); `POST /logins { refreshToken }` takes over a login from before #452 and renews
  it at once. Both answer `{ id, secret, accessToken, expiresAt, readsNotifications }`; the app shares
  `id` and `secret` with the user's other devices through iCloud Keychain.
- `POST /logins/<id>/token { secret, rejected? }` answers the current access token, renewed first when
  less than 15 minutes are left or Träwelling just refused `rejected`. The new tokens are saved before
  answering, and only one request renews at a time (`renewing`); the others wait for its tokens. Fetching
  changes nothing, so a lost answer costs nothing.
- `PUT /logins/<id> { secret, code, codeVerifier }` signs in again in place; `DELETE /logins/<id> { secret }`
  logs out (ends the Träwelling login and the notifications running on it). 404: the login has ended.
- The cron trigger renews logins nobody renewed for 20 days (refresh tokens would run out after 30) and
  ends those no device fetched a token from for 180 days, unless notifications run on them.

A D1 write happens only when something changed (a renewed login about once an hour, new check-ins).
Each look costs one Träwelling request per source (dashboard, notifications; one more when renewing)
plus one per notification; the free plan
allows 50 outgoing requests and 10 ms CPU per invocation, which fits a few dozen subscriptions per
minute. Beyond that, switch to Workers Paid.

## Webhook for likes and fellow travellers (#447)

While `TRAEWELLING_WEBHOOKS` is `"true"`, `GET /login-options` gives the app `trwl_webhook_url`
(`https://betterbahn-push.betterbahn.workers.dev/traewelling/webhook`) and `trwl_webhook_events=notification` to
add to the app's Träwelling login (`/logins`; before #452 the sign-up's own login). Träwelling then makes a webhook
for the user's notifications and returns its ID and secret with the token; the Worker keeps the secret sealed with
the login (AES-GCM, `TOKEN_KEY`) and pushes each delivery to every sign-up on that login. Each delivery
(`X-Trwl-Webhook-Id`, `Signature`: HMAC-SHA256 of the body) is checked and answered at once (Träwelling waits only
a second); the push follows. An unknown webhook gets `410`, on which Träwelling deletes it; signing off deletes it
too (`DELETE /api/v1/webhooks/<id>`), as do logging out and signing in again. Träwelling turns a webhook off after 5 failed deliveries in a row; the look
every 2 minutes then still finds everything.

To turn it on (once): on traewelling.de → Einstellungen → Anwendungen, edit the app (client 406), turn webhooks on
and enter the webhook URL above exactly. Then set `TRAEWELLING_WEBHOOKS = "true"` in `wrangler.toml` and
`npx wrangler deploy`. Before that, a login asking for a webhook fails, which is why the app only asks while the
Worker offers it. Only logins made after that get a webhook.

## Regular trips (`/commutes`, #397)

The same Worker looks after the journeys of regular trips ("Regelmäßige Fahrten" in the app). When the user
says yes to "Fährst du heute?", the app saves that day's journey and sends `PUT /commutes/<id> { secret,
deviceToken, sandbox, journeys }` (App Attest token): per train its DB category and number, boarding and exit
station (EVA number, name) with the planned times, and the delay threshold. `<id>` and `secret` are made on
the device; the first PUT signs it up, later ones replace the list, an empty list signs it off. The Worker
looks each train up in IRIS' hourly schedule (`plan`, keyless, the same feed the app's DB Timetables data
comes from) and answers `{ watched }`: the journeys it found every train of. The app reports the others
itself while it runs.

The cron trigger then reads IRIS' change list (`fchg`) of the stations involved every `INTERVAL_MINUTES`,
from 2 hours before the first departure until 10 minutes after the last arrival, and pushes: a cancellation
(once), a delay from the threshold on (again when it grew by 5 more minutes), a platform change within the
next 2 hours, and a transfer at risk (as the app's `ConnectionIssue`). The journey is forgotten 30 minutes
after its arrival and the row deleted when none is left. bahn.de is never asked (#334). Code and tests:
`commute.mjs`, `node --test Cloudflare/checkin-push/commute.test.mjs`.

A database made before #452 needs the `logins` table once:
`npx wrangler d1 execute betterbahn-push --remote --file=migrations/0002_server_logins.sql`, then
`npx wrangler deploy` (before the app version that keeps its login here ships).

A database made before #447 needs the new columns once:
`npx wrangler d1 execute betterbahn-push --remote --file=migrations/0001_own_checkin_notifications.sql`,
then `npx wrangler deploy` (before the app version that offers likes and fellow travellers ships).

An existing database needs the new table once:
`npx wrangler d1 execute betterbahn-push --remote --file=schema.sql` (everything in it is `IF NOT EXISTS`),
then `npx wrangler deploy`.

## Setup (once)

1. Apple Developer account → Certificates, Identifiers & Profiles → Keys → new key with "Apple Push
   Notifications service (APNs)". Download the `.p8` file (only possible once) and note its Key ID.
   The App ID `de.goldkunibert.BetterBahn` needs the Push Notifications capability; Xcode's automatic
   signing adds it from `Config/BetterBahn.entitlements` (`aps-environment`).
2. Then:

```sh
cd Cloudflare/checkin-push
npx wrangler d1 create betterbahn-push          # put the printed database_id into wrangler.toml
npx wrangler d1 execute betterbahn-push --remote --file=schema.sql
npx wrangler secret put TOKEN_SECRET            # same value as in betterbahn2 / betterbahn / betterbahn-stats / betterbahn-pass
openssl rand -base64 32 | npx wrangler secret put TOKEN_KEY
npx wrangler secret put APNS_KEY < AuthKey_XXXXXXXXXX.p8
# put the Key ID into APNS_KEY_ID in wrangler.toml
npx wrangler deploy
```

Don't change `TOKEN_KEY` later: the stored logins can't be read with another one, and every device
would have to turn the setting on again.

Check it with `curl https://betterbahn-push.betterbahn.workers.dev/health`. Then turn the setting on in
a development build (APNs sandbox) and have someone you follow check in; the Worker's logs
(`npx wrangler tail`) show failed APNs requests.

## Tests

`node --test Cloudflare/checkin-push/*.test.mjs` (Node 22.5+, uses `node:sqlite` for D1).
