# Train statistics (`betterbahn-stats`)

Answers the app with train statistics (#316): per train number and stop, how late the train was in the last
30 days, how often it was cancelled and which platforms it used. Regional and long-distance trains, no S-Bahn,
no buses; only German stops.

The data comes from [piebro/deutsche-bahn-data](https://github.com/piebro/deutsche-bahn-data)
([Hugging Face](https://huggingface.co/datasets/piebro/deutsche-bahn-data), CC BY 4.0, source Deutsche Bahn,
named in the app under Datenquellen): DB Timetables (IRIS) of every German station, the hourly plans and four
times a day every known change, reaching back more than six hours (#336). Neither the app nor this Worker asks
bahn.de for it any more, and the app reports nothing.

1. Once a day the GitHub Action `.github/workflows/train-stats-import.yml` (13:17 UTC, or by hand with a
   day) runs `importer.py`: it downloads yesterday's raw data and the next day's (trains past midnight, the
   next morning's changes), about 400 MB, and turns it into one row per train number and day (`schema.sql`,
   about 28,000 rows and 9 MB a day). A day is only imported once the next morning's changes are in the dataset.
   Days of the last 30 that are still missing are filled in too, as long as the rows written stay within the
   free plan (90,000 of D1's 100,000 a day): after the first run the 30 days take about ten days to fill.
   Days older than 30 are deleted on the way.
2. The app asks `POST /train-stats { trains: [{ category, number, evas: [...] }] }` (App Attest token, at
   most 8 trains with 12 stops each, 60 requests per minute per install): per train its runs of the last 30
   days (`STATS_DAYS`), cancelled runs, and per stop the arrival and departure delays, cancellations and
   platform moves (planned → actual). The app shows them only from 5 runs on.

Train numbers: DB Timetables knows a run by its number and category ("ICE 1095", but also "HLB 24010" or
"ag 84123" where the app says "RB"), so long-distance trains match by category and number, regional ones by
number and a stop the app asked for. The lower levels of big stations (Berlin Hbf tief …) are stored under
the main station (`LOWER_LEVELS` in `importer.py` and `worker.mjs`).

## Setup (once)

```sh
cd Cloudflare/stats
npx wrangler d1 create betterbahn-stats          # put the printed database_id into wrangler.toml
npx wrangler d1 execute betterbahn-stats --remote --file=schema.sql
npx wrangler secret put TOKEN_SECRET             # same value as in betterbahn2 / betterbahn / betterbahn-pass
npx wrangler deploy
```

For the import, add two repository secrets on GitHub (Settings → Secrets and variables → Actions):
`CLOUDFLARE_ACCOUNT_ID` (Cloudflare dashboard → Workers → Account ID) and `CLOUDFLARE_API_TOKEN` (an API
token with the permission "Account → D1 → Edit"). Then run the Action once by hand (Actions → Train statistics
import → Run workflow).

The database used to hold runs the Worker collected from bahn.de itself (#169, tables `runs`, `stations`,
`seed_stations`, `bahnde_pause`). Nothing reads them any more; to keep them, export them first, then drop them:

```sh
npx wrangler d1 export betterbahn-stats --remote --table=runs --output=runs.sql
npx wrangler d1 execute betterbahn-stats --remote --command "DROP TABLE runs; DROP TABLE stations; DROP TABLE seed_stations; DROP TABLE bahnde_pause"
```

Check it with `curl https://betterbahn-stats.betterbahn.workers.dev/health`. A look at the data:

```sh
npx wrangler d1 execute betterbahn-stats --remote --command "SELECT * FROM train_import ORDER BY day"
```

## Tests

`node --test Cloudflare/stats/worker.test.mjs` (Node 22.5+, uses `node:sqlite` for D1) and
`python3 -m unittest Cloudflare/stats/importer_test.py`. The Action runs both before importing.
A day by hand: `pip install pyarrow` and `python3 importer.py --day 2026-10-14 --sql day.sql` (about 90 s).
