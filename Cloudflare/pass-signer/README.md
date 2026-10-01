# Wallet pass signer

Apple Wallet only accepts passes signed with a Pass Type ID certificate. That certificate can't ship
inside the app, so the app (`WalletPassClient` in BetterBahnKit) sends the `pass.json` it built for a
DB ticket here and gets the signed `.pkpass` back.

`POST /pass` with the pass.json (max 16 KB):

- Only the genuine app may use it: requests need an App Attest access token (`X-BetterBahn-Token`)
  from the bahn.de proxy's `/auth` routes, checked with the shared `TOKEN_SECRET`
  (`../shared/appattest.mjs`). Without it the certificate would sign anybody's passes.
- Only the known keys are taken from the app (`serialNumber`, `description`, colours, dates,
  `barcodes`, `boardingPass`, …). `formatVersion`, `passTypeIdentifier`, `teamIdentifier` and
  `organizationName` ("BetterBahn") come from the Worker; anything else (e.g. `webServiceURL`) is dropped.
- The barcode is passed through unchanged: it is DB's own signed ticket code, read from the ticket
  PDF or a screenshot. The Worker never creates or changes a barcode.
- UIC ticket barcodes (`#UT`, e.g. every Deutschland-Ticket added from a screenshot) are only signed
  when their issuer's signature verifies (`uicsignature.mjs`): the barcode names the issuer (RICS code)
  and key ID, whose public key comes from UIC's list (`https://railpublickey.uic.org/download.php`,
  cached for a day, the last copy kept if UIC is down). DSA (1024/SHA-1, 2048/SHA-224/SHA-256) is
  checked with BigInt since WebCrypto has none, ECDSA through WebCrypto. A made-up or altered code gets
  `422 unverified_barcode`. Other barcode formats can only come from tickets the app fetched from
  bahn.de itself and pass as they are.
- Adds the icon Wallet requires (`images.mjs`, the app icon resized; no logo, so the pass front stays plain), writes `manifest.json` (SHA-1 of every
  file), a detached PKCS#7 `signature` (SHA-256, Apple's WWDR certificate included) and zips it.
- Answers `application/vnd.apple.pkpass` with `Cache-Control: no-store`. Nothing is stored or
  logged. `GET /health` answers without signing.

Errors: `400` invalid JSON or pass, `401` missing or invalid token, `405` not POST, `413` too large,
`422` UIC barcode signature doesn't verify, `503` secrets missing or UIC's key list unreachable,
`500` signing failed.

## Setup

1. In the Apple Developer portal (Certificates, Identifiers & Profiles → Identifiers → Pass Type IDs),
   register e.g. `pass.de.goldkunibert.BetterBahn.ticket`, then create a certificate for it and
   download `pass.cer`.
2. Convert it and its key (from the CSR's keychain entry, exported as `pass.p12`) to PEM, and fetch
   Apple's WWDR G4 certificate:

   ```sh
   openssl x509 -inform DER -in pass.cer -out pass-cert.pem
   openssl pkcs12 -in pass.p12 -nocerts -nodes -out pass-key.pem
   curl -sO https://www.apple.com/certificateauthority/AppleWWDRCAG4.cer
   openssl x509 -inform DER -in AppleWWDRCAG4.cer -out wwdr.pem
   ```

3. Store everything as secrets (never commit the PEMs):

   ```sh
   cd Cloudflare/pass-signer
   npm install
   npx wrangler secret put PASS_TYPE_ID   # pass.de.goldkunibert.BetterBahn.ticket
   npx wrangler secret put TEAM_ID        # the team ID from Config/Signing.xcconfig
   npx wrangler secret put PASS_CERT < pass-cert.pem
   npx wrangler secret put PASS_KEY < pass-key.pem
   npx wrangler secret put WWDR_CERT < wwdr.pem
   npx wrangler secret put TOKEN_SECRET   # the same value as in ../bahnde-proxy
   # optional: PASS_KEY_PASSWORD if the key is encrypted
   npx wrangler deploy
   ```

The Worker is `betterbahn-pass` (`https://betterbahn-pass.betterbahn.workers.dev`, see
`WalletPassClient.baseURL`), separate from the bahn.de proxy and the Träwelling callback.

## Verify

Unit tests (with a throwaway test certificate, generated DSA/ECDSA keys and a sample DB barcode):
`cd Cloudflare/pass-signer && npm install && npm test`.
During a rollout, `ALLOW_UNATTESTED = "true"` lets builds without App Attest through (see the proxy's README).

After deploying, add a ticket to Wallet from the app's ticket screen. If Wallet refuses the pass,
check the secrets: the pass type ID and team ID must match the certificate exactly.
