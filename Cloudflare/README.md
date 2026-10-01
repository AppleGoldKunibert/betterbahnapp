# Träwelling callback and privacy policy

`worker.mjs` (Worker `betterbahn`) also serves the privacy policy at
`https://betterbahn.betterbahn.workers.dev/datenschutz` (linked in the app's settings; use it as the
privacy policy URL in App Store Connect). Fill in the `[Name eintragen]` placeholder in
`PRIVACY_HTML` before deploying, and update the page whenever the app sends data somewhere new.

Keep the registered Träwelling redirect URI exactly:

    https://betterbahn.betterbahn.workers.dev/oauth/traewelling/callback

The authorization request and token exchange both use that HTTPS URI. The Worker
forwards the response to `betterbahn://oauth`, which the active
`ASWebAuthenticationSession` intercepts. This avoids the Associated Domains
entitlement. PKCE, state validation, and token storage stay in the app; the Worker
does not exchange or store tokens and needs no Client Secret.

## Update the existing Worker

`worker.mjs` is the complete Worker source: the privacy policy, the callback
(a fixed redirect to the app) and a 404 fallback. The old
`apple-app-site-association` response is gone; the login never used it.

In the Cloudflare dashboard, open `betterbahn`, choose **Edit code**, replace the
entry module's contents with `worker.mjs`, and deploy. No dependencies, secrets,
or new bindings are required.

Deploy the updated Worker before testing login. Avoid logging callback query
strings because they contain authorization codes.

## Verify

Run the handler tests with `node --test Cloudflare/traewelling-callback.test.mjs`.
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
