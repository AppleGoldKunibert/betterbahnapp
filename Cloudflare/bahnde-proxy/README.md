# Timetables and App Attest Worker (`betterbahn2`)

This Worker forwards DB's Timetables API with our API key and hands out the App Attest tokens every request
to our servers needs. It used to forward bahn.de's web API too (`/web/api/…`), but bahn.de refuses Workers
since October 2026; the app asks bahn.de only through `../../Server/bahnde-proxy`, so those paths are gone.
The app still builds its bahn.de URLs on this Worker's address (`BahnDeClient.baseURL`) and `BahnDeProxy`
rewrites them to the server.

| Path | Cached for |
| --- | --- |
| `/timetables/v1/plan/<eva>/<yymmdd>/<hh>` | 30 min |
| `/timetables/v1/fchg/<eva>` | 30 s |
| `/timetables/v1/station/<eva>` | 1 day |

Only these GET paths (and `/auth/…`) are allowed; everything else is 404. Errors are passed through uncached.
`GET /health` answers without calling upstream.

Timetables requests go to the keyless IRIS (`iris.noncd.db.de`, the service behind Timetables, which DB's own
departure board uses) first. Only when IRIS fails (error, timeout, 5xx, 429) they go to DB's API Marketplace with
`DB-Client-Id`/`DB-Api-Key` from this Worker's secrets, so the key never ships in the app and the Marketplace's
60 calls/minute are kept for when IRIS is down. IRIS's "no data" answers (400/404/410) are passed on without a
fallback. DB marked IRIS deprecated, so the Marketplace stays configured.

## App Attest

Only the genuine app may use the proxy (and the pass signer): every request needs an
`X-BetterBahn-Token`, which this Worker hands out after Apple's App Attest proved the request comes
from BetterBahn on a real device (`../shared/appattest.mjs`, app side `WorkerAuth`):

1. `GET /auth/challenge` → a signed challenge (5 min).
2. `POST /auth/attest {keyId, attestation, challenge}` → a key token, once per installation. The
   attestation's certificates must chain to Apple's App Attestation root, and its app ID must be in
   `APP_IDS` (`wrangler.toml`).
3. `POST /auth/token {keyToken, assertion, challenge}` → an access token valid for 1 hour.

The Android app gets the same access token with Google's Play Integrity instead of steps 2 and 3
(`../shared/playintegrity.mjs`): `POST /auth/play {integrityToken, challenge}`. The app asks Play for a
token with `requestHash` = hex SHA-256 of the challenge; the Worker lets Google decode it (service account
key in `PLAY_INTEGRITY_KEY`) and wants our package (`PLAY_PACKAGE`, default `de.goldkunibert.betterbahn`),
the matching hash, at most 5 minutes old, `PLAY_RECOGNIZED` and `MEETS_DEVICE_INTEGRITY`.
`PLAY_INTEGRITY_ALLOW_TESTING = "true"` skips the last two (emulator, sideloaded debug build); for
testing only. Without `PLAY_INTEGRITY_KEY` the route answers 503.

Nothing is stored: challenges and tokens are HMAC-signed with `TOKEN_SECRET`. Rotating it makes
every app attest a new key. Builds without App Attest (Simulator, Mac) get no token, so bahn.de,
Timetables and Wallet don't work there unless `ALLOW_UNATTESTED` is set (Timetables never works
without a token, since it spends the API key).

This is a separate Worker (`betterbahn2`) from the Träwelling callback (`../worker.mjs`), so abuse here can't
affect login. It fits the free Workers plan (100,000 requests/day).

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
npx wrangler secret put PLAY_INTEGRITY_KEY   # Android: the service account's JSON key (docs/android.md)
```

Rollout: while older builds without App Attest are still installed, set `ALLOW_UNATTESTED` to
`"true"` (`[vars]` in `wrangler.toml` or the dashboard) so their requests keep working, and remove
it once every device runs a build with `WorkerAuth`. The old key that used to ship in the app should
be rotated in the API Marketplace after the switch.

## Verify

Unit tests: `node --test Cloudflare/bahnde-proxy/worker.test.mjs Cloudflare/shared/*.test.mjs`.

After deploying, `curl https://betterbahn2.betterbahn.workers.dev/health` answers `{"ok":true}`; Timetables
needs a token from the app (`-H 'X-BetterBahn-Token: …'`).
