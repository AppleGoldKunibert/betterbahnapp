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

Query strings are forwarded unchanged. Only these GET paths are allowed; everything else is 404.
bahn.de errors (including 403/429 blocks) are passed through uncached, so the app's `BahnDeGate`
cooldown still applies. `GET /health` answers without calling bahn.de.

This is a separate Worker (`betterbahn2`) from the Träwelling callback (`../worker.mjs`), so a block or abuse here
can't affect login. It fits the free Workers plan (100,000 requests/day).

## Deploy

```sh
cd Cloudflare/bahnde-proxy
npx wrangler login
npx wrangler deploy
```

Optional: require a shared token so the proxy isn't open to everyone. The app then has to send it
as `X-BetterBahn-Token`.

```sh
npx wrangler secret put PROXY_TOKEN
```

## Verify

Unit tests: `node --test Cloudflare/bahnde-proxy/worker.test.mjs`.

`npx wrangler dev` runs the Worker locally, but requests then leave from your own connection, so it
only checks the code. Whether bahn.de accepts requests from Cloudflare's network shows only after
deploying (it did on 2026-09-30: stations, boards and coach sequences all answered 200). Use a
departure bahn.de already has a coach sequence for (the next morning worked late the evening
before), and add `-H 'X-BetterBahn-Token: …'` if you set a token:

```sh
curl -i 'https://betterbahn2.kunibert88.workers.dev/web/api/reisebegleitung/wagenreihung/vehicle-sequence?administrationId=80&category=ICE&date=2026-09-30&evaNumber=8000105&number=117&time=2026-09-30T06:10:00.000Z'
```

`200` with a `groups` array (e.g. `"name":"ICE9226"`) means Cloudflare gets through; `403` with
`OPS_BLOCKED` means bahn.de blocks Cloudflare too.
