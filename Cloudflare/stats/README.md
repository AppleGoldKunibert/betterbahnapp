# Train statistics (`betterbahn-stats`)

Collects realtime data for later statistics (#169): delays and platforms per stop, cancelled and
additional stops, disruption messages and the Wagenreihung (vehicle types and numbers) of every
regional and long-distance train an app user has seen. No S-Bahn, no buses; only trains with a stop
in Germany and realtime data.

1. The app reports the bahn.de journey IDs of trains it showed (boards, search results, a train's
   stops) to `POST /sightings { journeyIds: [...] }` (App Attest token, at most 100 per request,
   30 requests per minute per install). No user ID, no location. Users can switch this off in
   Settings → "Zugdaten für Statistik teilen".
2. Every minute the cron trigger looks at the due runs (`BATCH`, default 8) and asks bahn.de itself:
   - right away: the run's schedule (`reiseloesung/fahrt`). Trains without a German stop are dropped.
   - 10 minutes before departure: the Wagenreihung at the first stop.
   - 30 minutes after arrival at the terminus (later while it runs late): the final realtime state.
     Runs without any realtime data are dropped.
3. Everything lands in D1, one row per run (`schema.sql` describes the columns and the compact stop
   format, with an example query).

Size: a finished run takes well under 1 KB, so the free plan's 5 GB hold roughly 10,000–25,000 runs a
day for a year. The free plan's CPU limit allows about `BATCH` = 8 runs a minute, i.e. roughly 4,000
trains a day (three looks each). Above that, switch to Workers Paid (5 $/month) and raise `BATCH`.

## Setup (once)

```sh
cd Cloudflare/stats
npx wrangler d1 create betterbahn-stats          # put the printed database_id into wrangler.toml
npx wrangler d1 execute betterbahn-stats --remote --file=schema.sql
npx wrangler secret put TOKEN_SECRET             # same value as in betterbahn2 / betterbahn / betterbahn-pass
npx wrangler deploy
```

Check it with `curl https://betterbahn-stats.betterbahn.workers.dev/health`. A look at the data:

```sh
npx wrangler d1 execute betterbahn-stats --remote --command "SELECT state, count(*) FROM runs GROUP BY state"
```

## Backup and cleanup (runs older than a year)

`./backup.sh` downloads every day older than a year into `backups/<day>.json.gz` (plus
`backups/stations.json.gz`), checks the file has every run of that day, and only then deletes that day
from D1. Nothing is deleted without a backup, so run it now and then (e.g. monthly) from your Mac;
`backups/` is not committed. D1's Time Travel can also restore the database to any point in the last
30 days (`npx wrangler d1 time-travel restore`).

## Tests

`node --test Cloudflare/stats/worker.test.mjs` (Node 22.5+, uses `node:sqlite` for D1).
