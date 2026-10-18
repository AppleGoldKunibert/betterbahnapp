# Live Activity updates (`betterbahn-live`)

Keeps a journey's Live Activity current while the app is closed (#315, Settings → Meine Reisen "Live-Aktivität
über Server aktualisieren", on by default). iOS runs the app's background refresh when it likes, often much later
than asked, so the activity showed old delays and platforms until the app was opened again.

1. The app starts the activity with an ActivityKit push token. When it goes to the background, it hands the
   activity over: `PUT /activities/<id> { secret, pushToken, sandbox, journey }` (App Attest token). `id` and
   `secret` are made up by the app; `journey` is `LiveActivityPushJourney`: the journey's trains with their stops,
   times and platforms as the app last saw them, and their IRIS category, number and EVA numbers.
2. Every minute the cron trigger looks at the activities that are due, on the app's own schedule
   (`LiveActivityRefreshSchedule`: every 2 minutes, around each arrival, every minute while transferring). It asks
   DB's IRIS (keyless, as bahn.expert does) about what the activity shows now: the current train's departure
   until it has left, then its next stop, its arrival and the next train's departure. Where a train is in IRIS
   (`plan`) is looked up once and kept; its live data comes from the station's change list (`fchg`), each asked
   once per run for all activities.
3. It works out the activity's state as the app does (`state.mjs`, a copy of
   `TripActivityAttributes.ContentState.from`) and pushes it (`apns-push-type: liveactivity`) when it differs from
   the last one: urgent when times, platforms or warnings changed, not urgent when the activity only moved on as it
   already shows by itself. A minute after the final arrival it ends the activity ("Angekommen" stays 5 minutes)
   and deletes the row.
4. When the app comes back to the foreground it updates the activity itself again and takes it back:
   `DELETE /activities/<id> { secret }`.

Stored per activity: its push token, the journey (trains, station names, EVA numbers, times, platforms) and the
state last pushed, from going to the background until the arrival (or the app being opened). No location, nothing
about the user.

Keep `state.mjs` in step with the app: `Fixtures/live-activity-push.json` in the Kit tests holds journeys and the
states for them, checked by both `LiveActivityPushTests` (Swift) and `worker.test.mjs`.

## Costs

Per look up to three `fchg` requests (often two: the arrival and the next departure share a station), plus once
per stop a `plan` request and one APNs request when something changed. The free plan allows 50 outgoing requests
and 10 ms CPU per invocation: `BATCH` (default 6) activities per run, so a few dozen running at once. Beyond that,
switch to Workers Paid and raise `BATCH`. A D1 write happens per look.

## Setup (once)

Uses the APNs auth key of `betterbahn-push` (see its README; the same key may be used by several servers).

```sh
cd Cloudflare/live-activity
npx wrangler d1 create betterbahn-live          # put the printed database_id into wrangler.toml
npx wrangler d1 execute betterbahn-live --remote --file=schema.sql
npx wrangler secret put TOKEN_SECRET            # same value as in betterbahn2 / betterbahn-push / …
npx wrangler secret put APNS_KEY < AuthKey_XXXXXXXXXX.p8
npx wrangler deploy
```

Check it with `curl https://betterbahn-live.betterbahn.workers.dev/health`. Then start a Live Activity in a
development build (APNs sandbox), close the app and watch `npx wrangler tail`.

## Tests

`node --test Cloudflare/live-activity/worker.test.mjs` (Node 22.5+, uses `node:sqlite` for D1).
