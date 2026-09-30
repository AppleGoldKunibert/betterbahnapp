# Wallet pass signer

Apple Wallet only accepts passes signed with a Pass Type ID certificate. That certificate can't ship
inside the app, so the app (`WalletPassClient` in BetterBahnKit) sends the `pass.json` it built for a
DB ticket here and gets the signed `.pkpass` back.

`POST /pass` with the pass.json (max 16 KB):

- Only the known keys are taken from the app (`serialNumber`, `description`, colours, dates,
  `barcodes`, `boardingPass`, …). `formatVersion`, `passTypeIdentifier` and `teamIdentifier` come
  from the Worker; anything else (e.g. `webServiceURL`) is dropped.
- The barcode is passed through unchanged: it is DB's own signed ticket code, read from the ticket
  PDF. The Worker never creates or changes a barcode.
- Adds the icon Wallet requires (`images.mjs`, the app icon resized; no logo, so the pass front stays plain), writes `manifest.json` (SHA-1 of every
  file), a detached PKCS#7 `signature` (SHA-256, Apple's WWDR certificate included) and zips it.
- Answers `application/vnd.apple.pkpass` with `Cache-Control: no-store`. Nothing is stored or
  logged. `GET /health` answers without signing.

Errors: `400` invalid JSON or pass, `401` wrong token, `405` not POST, `413` too large,
`503` secrets missing, `500` signing failed.

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
   # optional: PASS_KEY_PASSWORD if the key is encrypted, PROXY_TOKEN to require X-BetterBahn-Token
   npx wrangler deploy
   ```

The Worker is `betterbahn-pass` (`https://betterbahn-pass.kunibert88.workers.dev`, see
`WalletPassClient.baseURL`), separate from the bahn.de proxy and the Träwelling callback.

## Verify

Unit tests (with a throwaway test certificate): `cd Cloudflare/pass-signer && npm install && npm test`.

After deploying, add a ticket to Wallet from the app's ticket screen. If Wallet refuses the pass,
check the secrets: the pass type ID and team ID must match the certificate exactly.
