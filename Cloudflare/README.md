# Träwelling callback, privacy policy and share links

`worker.mjs` (Worker `betterbahn`) also serves the privacy policy at
`https://betterbahn.betterbahn.workers.dev/datenschutz` (linked in the app's settings; use it as the
privacy policy URL in App Store Connect), and a support page at `/support` (the support URL in App Store
Connect). Update the privacy page (`PRIVACY_HTML`) whenever the app sends data somewhere new.

It also stores shared journeys for short links (`https://betterbahn.betterbahn.workers.dev/s/<id>`):

- `POST /share { data }` → `201 { id, url, expiresAt }`. Needs an App Attest token
  (`X-BetterBahn-Token`, same `TOKEN_SECRET` as `betterbahn2`); 10 per minute per app install.
- `GET /share/<id>` → `{ data }` (404 when unknown or expired); 60 per minute per IP.
- `GET /s/<id>` → fallback page for browsers without the app ("In BetterBahn öffnen" via
  `betterbahn://share?id=<id>`, App Store link once `APP_STORE_URL` is set).
- `/.well-known/apple-app-site-association` → Universal Links for `/s/*` (`APP_IDS`), so iOS opens the
  app directly (Associated Domains entitlement in `Config/BetterBahn.entitlements`).

"Ankunft teilen" (#317, `arrival.mjs`): `POST /share { data, arrival }` also stores the last train of the
journey (`ArrivalShare` in the app: train, product/color, bahn.de journey ID, stops from boarding to getting
off). Such a link expires 2 hours after the arrival (later when the train runs late, at most 12 hours after
the planned arrival), and `/s/<id>` shows a small page with the arrival time, delay, platform and stops in any
browser. The page refreshes from `GET /share/<id>/live`, which reads bahn.de's journey details (`fahrt`, from the
Worker itself with the proxy's browser headers, cached 30 s per train); without them it shows the app's times.
With the app installed, iOS still opens the app, which shows the journey as before.

`data` is the same zlib/base64url payload as in `betterbahn://share?data=…`; the Worker only checks
its characters and size (64 KiB) and keeps it in KV (`SHARES`) for 30 days. The app falls back to the
long link when this fails, and old long links keep working.

Keep the registered Träwelling redirect URI exactly:

    https://betterbahn.betterbahn.workers.dev/oauth/traewelling/callback

The authorization request and token exchange both use that HTTPS URI. The Worker
forwards the response to `betterbahn://oauth`, which the active
`ASWebAuthenticationSession` intercepts. This avoids the Associated Domains
entitlement. PKCE, state validation, and token storage stay in the app; the Worker
does not exchange or store tokens and needs no Client Secret.

## Update the existing Worker

`worker.mjs` (with `arrival.mjs`, `shared/appattest.mjs` and the bahn.de helpers it imports from `bahnde-proxy/` and `stats/`) is the complete Worker source: the pages, the callback
(a fixed redirect to the app), share links and a 404 fallback. The association file only covers
`/s/*`, so the OAuth callback still opens in the browser session.

Since the Worker imports `shared/`, deploy it with Wrangler from this directory instead of pasting it
into the dashboard:

```sh
cd Cloudflare
npx wrangler kv namespace create SHARES   # once; put the id into wrangler.toml
npx wrangler secret put TOKEN_SECRET      # once; same value as in betterbahn2 / betterbahn-pass
npx wrangler deploy
```

Deploy the updated Worker before testing login. Avoid logging callback query
strings because they contain authorization codes.

## Verify

Run the handler tests with `node --test Cloudflare/traewelling-callback.test.mjs Cloudflare/share.test.mjs Cloudflare/arrival.test.mjs`.
After deploying, this synthetic request should return HTTP 302 with
`Location: betterbahn://oauth?code=test-code&state=test-state`:

```sh
curl -i 'https://betterbahn.betterbahn.workers.dev/oauth/traewelling/callback?code=test-code&state=test-state'
```

Do not follow this test redirect or use real authorization codes in shell commands.
For the real test, select your Personal Team in Xcode, run BetterBahn on your
iPhone, enter the public Träwelling application's Client ID in settings, and start
login from the app. The browser should close after authorization. Opening the
callback manually does not constitute a login.
