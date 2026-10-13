# Check-in notifications (`betterbahn-push`)

Push notifications for new check-ins of the people a Träwelling user follows (#266, Settings →
Träwelling "Check-ins von Gefolgten melden"). iOS decides on its own when an app may look in the
background, often hours later, so the app doesn't look itself; this Worker does.

1. Turning the setting on signs in with Träwelling a second time, for this Worker only and with just
   `read-statuses`. The app sends the authorization code with its PKCE verifier, its APNs device token
   and the Träwelling user ID to `POST /subscriptions` (App Attest token) and gets `{ id, secret }`
   back. The Worker exchanges the code itself, so this login never exists on the device. The app's own
   login stays untouched: Träwelling's access tokens last an hour and each refresh token works once,
   so the two can't share one.
2. Every minute the cron trigger looks at the subscriptions due in that minute (each one every
   `INTERVAL_MINUTES`, default 2): it renews the login when it expired, loads the dashboard (first
   page) and sends an APNs notification for each check-in of someone else that is new and under way
   or leaving within 20 minutes (the app's rule). The first look only remembers what runs already.
3. `PUT /subscriptions/<id> { secret, deviceToken, sandbox }` keeps the device token current (the app
   sends it on every start); `DELETE /subscriptions/<id> { secret }` (setting off, Träwelling logout)
   deletes the row and ends the Worker's Träwelling login.

When Träwelling ends the login or APNs says the app is gone, the row is deleted; the app then gets a
404 and turns the setting off. Stored per device: device token, Träwelling user ID, the login
(AES-GCM with `TOKEN_KEY`) and the IDs of the check-ins already seen. No location, no names.

A D1 write happens only when something changed (a renewed login about once an hour, new check-ins).
Each look costs one Träwelling request (two when renewing) plus one per notification; the free plan
allows 50 outgoing requests and 10 ms CPU per invocation, which fits a few dozen subscriptions per
minute. Beyond that, switch to Workers Paid.

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

`node --test Cloudflare/checkin-push/worker.test.mjs` (Node 22.5+, uses `node:sqlite` for D1).
