# bahn.de proxy

bahn.de's bot protection answers `403 OPS_BLOCKED` to requests from Apple's URL loading stack,
whatever headers `BahnDeClient` sends (curl or Travel::Status::DE::DBRIS from the same machine get
through). This Worker makes the request instead, with the same DBRIS browser headers.

Paths mirror `https://www.bahn.de/web/api/…`, so the app only swaps `BahnDeClient.baseURL`:

| Proxy path | Cached for |
| --- | --- |
| `/web/api/reiseloesung/orte`, `/orte/nearby` | 1 day |
| `/web/api/reiseloesung/abfahrten`, `/ankuenfte`, `/fahrt` | 30 s |
| `/web/api/reisebegleitung/wagenreihung/vehicle-sequence` | 2 min |
| `/web/api/angebote/verbindung/<vbid>` (shared connections, UUID only) | 1 h |
| `/timetables/v1/plan/<eva>/<yymmdd>/<hh>` (DB Timetables) | 30 min |
| `/timetables/v1/fchg/<eva>` (DB Timetables) | 30 s |
| `/timetables/v1/station/<eva>` (DB Timetables) | 1 day |

Query strings are forwarded unchanged (not for Timetables). Only these GET paths are allowed;
everything else is 404. bahn.de errors (including 403/429 blocks) are passed through uncached, so
the app's `BahnDeGate` cooldown still applies. `GET /health` answers without calling bahn.de.

Timetables requests go to DB's API Marketplace with `DB-Client-Id`/`DB-Api-Key` from this Worker's
secrets, so the key never ships in the app.

## App Attest

Only the genuine app may use the proxy (and the pass signer): every request needs an
`X-BetterBahn-Token`, which this Worker hands out after Apple's App Attest proved the request comes
from BetterBahn on a real device (`../shared/appattest.mjs`, app side `WorkerAuth`):

1. `GET /auth/challenge` → a signed challenge (5 min).
2. `POST /auth/attest {keyId, attestation, challenge}` → a key token, once per installation. The
   attestation's certificates must chain to Apple's App Attestation root, and its app ID must be in
   `APP_IDS` (`wrangler.toml`).
3. `POST /auth/token {keyToken, assertion, challenge}` → an access token valid for 1 hour.

Nothing is stored: challenges and tokens are HMAC-signed with `TOKEN_SECRET`. Rotating it makes
every app attest a new key. Builds without App Attest (Simulator, Mac) get no token, so bahn.de,
Timetables and Wallet don't work there unless `ALLOW_UNATTESTED` is set (Timetables never works
without a token, since it spends the API key).

This is a separate Worker (`betterbahn2`) from the Träwelling callback (`../worker.mjs`), so a block or abuse here
can't affect login. It fits the free Workers plan (100,000 requests/day).

## Deploy

```sh
cd Cloudflare/bahnde-proxy
npx wrangler login
npx wrangler deploy
```

Secrets (the same `TOKEN_SECRET` in `../pass-signer`, e.g. from `openssl rand -base64 32`):

```sh
npx wrangler secret put TOKEN_SECRET
npx wrangler secret put DB_CLIENT_ID   # DB API Marketplace, Timetables
npx wrangler secret put DB_API_KEY
```

Rollout: while older builds without App Attest are still installed, set `ALLOW_UNATTESTED` to
`"true"` (`[vars]` in `wrangler.toml` or the dashboard) so their requests keep working, and remove
it once every device runs a build with `WorkerAuth`. The old key that used to ship in the app should
be rotated in the API Marketplace after the switch.

## Verify

Unit tests: `node --test Cloudflare/bahnde-proxy/worker.test.mjs Cloudflare/shared/appattest.test.mjs`.

`npx wrangler dev` runs the Worker locally, but requests then leave from your own connection, so it
only checks the code. Whether bahn.de accepts requests from Cloudflare's network shows only after
deploying (it did on 2026-09-30: stations, boards and coach sequences all answered 200). Use a
departure bahn.de already has a coach sequence for (the next morning worked late the evening
before), with `ALLOW_UNATTESTED` set (or a token from the app as `-H 'X-BetterBahn-Token: …'`):

```sh
curl -i 'https://betterbahn2.betterbahn.workers.dev/web/api/reisebegleitung/wagenreihung/vehicle-sequence?administrationId=80&category=ICE&date=2026-09-30&evaNumber=8000105&number=117&time=2026-09-30T06:10:00.000Z'
```

`200` with a `groups` array (e.g. `"name":"ICE9226"`) means Cloudflare gets through; `403` with
`OPS_BLOCKED` means bahn.de blocks Cloudflare too.
