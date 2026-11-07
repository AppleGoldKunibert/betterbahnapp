# Live train positions Worker (`betterbahn-positions`)

Gives the app (`RISMapsClient` in BetterBahnKit) the live positions of running trains from DB's RIS::Maps (DB API
Marketplace). The app asks this Worker first and bahn.jetzt only when it doesn't answer or doesn't know the train.

| Path | Cached for |
| --- | --- |
| `GET /journeys` | 15 s |
| `GET /health` | – (answers without calling upstream) |

`/journeys` always asks for the whole list (`POST …/db/apis/ris-maps/v2/journey-positions/` with the administrations
in `ADMIN_IDS`, else `DEFAULT_ADMIN_IDS`: DB Fernverkehr and DB Regio's regional companies and S-Bahns), so all users
share one cached answer and the app never says which train it looks at. Upstream sends `RISMAPS-App-Id:
livemap-WebSdk` (RIS::Maps' client ID for live positions) and our `DB-Client-Id`/`DB-Api-Key`.

The answer is a compact list (about 180 trains, ~40 KB before compression):

```json
{ "fetchedAt": "2026-11-03T03:24:00.000Z",
  "trains": [ { "id": "20261102-517e…", "category": "ICE", "number": 921, "name": "ICE 921",
                "type": "HIGH_SPEED_TRAIN", "origin": "Hamburg-Altona", "originEva": "8002553",
                "destination": "Köln Hbf", "destinationEva": "8000207", "lat": 50.94, "lon": 6.97, "speed": 26.7,
                "time": "2026-11-03T03:23:48Z", "source": "SENSOR" } ] }
```

`id` is RIS' journey ID (the same as bahn.expert's and bahn.jetzt's; the app opens a train's route with it when
Transitous has no matching trip), `type` RIS' transport type, `number` the train number (for regional trains
the run number, `line` the line name, e.g. "RE51"), `time` when the fix was taken, `source` `SENSOR` (GPS on the
train) or `SIGNALLING` (from the interlocking, can be a minute or two old). `speed` (km/h) is missing when unknown.

Every request needs an App Attest token (`X-BetterBahn-Token`) from `betterbahn2`'s `/auth` routes, checked with
the shared `TOKEN_SECRET`; `ALLOW_UNATTESTED` is ignored, since every upstream call spends our API key. Upstream
errors are not cached: 429 is passed on (the app pauses), anything else answers 502 (the app falls back to
bahn.jetzt).

The Marketplace allows 25,000 calls a day for RIS::Maps; one call per 15 s and Cloudflare location is 5,760.

## Administrations

RIS::Maps only answers for the administrations (railway undertakings) asked for. To find
the ID of a train that is missing, look up its journey on bahn.expert (`journey/detailsByJourneyId` → `train.admin`)
and add it to `ADMIN_IDS` in `wrangler.toml` (comma-separated; it then replaces the whole default list) or to
`DEFAULT_ADMIN_IDS` in `worker.mjs`.

## Deploy

```sh
cd Cloudflare/positions
npx wrangler login
npx wrangler deploy
npx wrangler secret put TOKEN_SECRET   # the same value as in ../bahnde-proxy (betterbahn2)
npx wrangler secret put DB_CLIENT_ID   # DB API Marketplace application subscribed to RIS::Maps
npx wrangler secret put DB_API_KEY
```

## Verify

Unit tests: `node --test Cloudflare/positions/worker.test.mjs`.

After deploying, `curl https://betterbahn-positions.betterbahn.workers.dev/health` answers `{"ok":true}`;
`/journeys` answers 401 without a token from the app.
