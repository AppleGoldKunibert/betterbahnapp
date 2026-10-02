# BetterBahn – codebase guide

Quick orientation so a new session doesn't have to re-explore the repo. Read this first; open
source files only for the part you're changing. Keep it up to date when structure changes.

## What it is

Personal iOS app (SwiftUI, iOS 26, Swift 6) for German train travel: journey search, station
boards, trip details, saved journeys with Live Activities, travel heatmap, Träwelling check-ins,
importing connections shared from DB Navigator / bahn.de. **UI text is German**; code and
comments are English.

## Layout

| Path | Contents |
| --- | --- |
| `BetterBahn/` | App target (UI + app state). Default actor isolation is **MainActor** (hence `nonisolated` on some types). `PrivacyInfo.xcprivacy` declares the required-reason APIs (UserDefaults); keep it current when using new ones. |
| `BetterBahnWidgets/` | Widget extension: `TripLiveActivity` (Lock Screen / Dynamic Island). |
| `BetterBahnShare/` | Share extension: `ShareViewController` takes shared DB text/URL and opens `betterbahn://import?...`. |
| `Packages/BetterBahnKit/` | Local SwiftPM package with all models, networking and logic (iOS 26 + macOS 26, everything `Sendable`). Tests live here. |
| `Config/` | xcconfigs + Info.plists. `Signing.xcconfig` holds team ID; optional gitignored `Local.xcconfig` overrides it. |
| `Cloudflare/` | Worker (`betterbahn`) that bounces the Träwelling OAuth callback to `betterbahn://oauth` and serves the privacy policy at `/datenschutz` (linked in Settings) and the support page at `/support` (see its README). |
| `Cloudflare/bahnde-proxy/` | Separate Worker (`betterbahn2`) proxying bahn.de's web API (`/web/api/…` paths), because bahn.de blocks Apple's URL loading stack, and DB Timetables (`/timetables/v1/…`, API key as Worker secret). Also hands out the App Attest tokens (`/auth/…`). See its README. `BahnDeClient.baseURL`, `TimetablesClient.baseURL` point at it. |
| `Cloudflare/pass-signer/` | Worker (`betterbahn-pass`) that signs Apple Wallet passes for DB tickets with the Pass Type ID certificate (secrets), since that can't ship in the app. Needs an App Attest token, and only signs UIC (`#UT`) barcodes whose issuer signature verifies against UIC's public key list (`uicsignature.mjs`). `npm install && npm test` (see its README). |
| `Cloudflare/shared/` | `appattest.mjs`: App Attest verification and the signed tokens both Workers check (`X-BetterBahn-Token`); `node --test Cloudflare/shared/appattest.test.mjs`. |
| `.github/workflows/` | GitHub Actions: `pr-build.yml` (macOS: Kit tests + unsigned app build on PRs touching code), `pr-secrets.yml` (Linux: gitleaks secret scan + guard against committing `DefaultCredentials.swift`), `sync-prod.yml` (merges prod into every other branch except `appstorerelease`). |
| `docs/transit-providers.md` | Why Transitous is the primary data source and fallback options. |
| `docs/app-review-notes.md` | App Store submission checklist (privacy URL, App Privacy, demo access) and review notes. |

Targets/schemes: `BetterBahn`, `BetterBahnWidgetsExtension`, `BetterBahnShareExtension`, `BetterBahnKit`.
Bundle IDs: `de.goldkunibert.BetterBahn[.Widgets|.Share]`. URL scheme: `betterbahn://`.

## App target (`BetterBahn/`)

- `App/BetterBahnApp.swift` – `@main`, `AppDelegate` (registers BG task for ending Live
  Activities), `RootView` with 4 tabs: Verbindungen (`ConnectionsView`), Karte (`TravelMapView`),
  Abfahrten (`StationBoardView`), Einstellungen (`SettingsView`). Handles `onOpenURL`
  (`DBShare.text(fromAppURL:)` → `ImportedJourneyView`, `JourneyShareLink` → `SharedJourneyPreviewView`, `LiveActivityLink` from tapping the Live Activity → that saved
  journey via `AppModel.journeyToOpen` on the Verbindungen tab)
  and scene-phase refresh start/stop.
- `App/AppModel.swift` – the single `@Observable` app state, injected via `.environment(model)`.
  Owns `CombinedProvider`, `TraewellingClient`, helpers (`TrainPicker`, `JourneyReplanner`,
  `DBShareImporter`, `TrainRoutePlanner`, `TicketFilter`, `TimetablesClient`, `JourneyRefresher`),
  persisted lists (favorites, recents, `savedJourneys`, `traewellingTrips`, tracked manual check-ins),
  realtime refresh loops (journeys every 300 s, the Live Activity's journey per `LiveActivityRefreshSchedule` – 2 min, ±1 min around arrivals, 1 min while transferring; train positions only while the map is shown, every 15 s or 60 s on mobile data/Low Data Mode), delay notifications,
  geometry/heatmap caches, Live Activity selection. Also defines `SavedJourney`, `PlanVersion`,
  `ImportedTrip`, `RecentSearch`, `Storage`, `AppSettings`, `ConnectionNotifier`.
- **Persistence:** `Storage.save/load(key:)` writes JSON to `Application Support/BetterBahn/<key>.json`
  (migrates from old UserDefaults). `AppSettings` uses UserDefaults directly. Saved data must stay
  decodable across versions (e.g. `DataSource.dbRest` kept only for decoding).
- `App/CloudSync.swift` – iCloud key-value store mirror (entitlement in `Config/BetterBahn.entitlements`):
  favorites, recent searches and saved journeys sync item by item via `CloudList` (Kit `SyncedList`:
  newest change per item wins, removals kept as dates); `AppSettings` syncs as one snapshot, the newer one
  wins. The Träwelling token syncs via iCloud Keychain (`TokenStore`); a 401 retries with a token another
  device refreshed before logging out.
- `App/TicketStore.swift` – `SavedTicket` (a `DBTicket` + the `SavedJourney.id` it belongs to), stored only on
  this device in `Application Support/BetterBahn/Tickets/` (list + PDFs, file protection, **not** synced via
  iCloud), and the `AppModel` ticket functions (`importTickets` matches a saved journey or imports the booked
  connection via `DBShareImporter.journey(from:)`).
- `App/LiveActivityManager.swift` – ActivityKit wrapper; attributes in Kit `TripActivityAttributes`.
- `Features/Connections/` – search form (`ConnectionsView`, `ConnectionSearch`, `RouteOptionsEditor`
  for via stops/products/max transfers), `JourneyResultsView` (+ `JourneyCard`, `TrainNumberSheet`),
  `JourneyDetailView` (+ `LegCard`, `TransferRow`, alternatives sheets), `JourneyMapView` (MapKit),
  `JourneyReplanSheet` (replan from mid-journey).
- `Features/Departures/` – `StationBoardView`/`BoardRow`, `TripView` (single train's stops),
  `CoachSequenceView` (Wagenreihung sheet, opened from `CoachSequenceButton` in train headers or a stop's platform in `TripContent`).
- `Features/Map/` – `TravelMapView` heatmap of past trips (`TravelMapHeatmap`, railway tile overlay),
  `LiveTrainMapView` (one train's live position on its route, opened from `LiveTrainIconTile`, the train icon on
  legs and trips bahn.jetzt has). `JourneyMapView` shows the journey's running trains too.
- `Features/Tickets/` – `TicketLookupView` (native form; bahn.de's "Auftragssuche" runs in a hidden SwiftUI `WebView`,
  `DBOrderPage.fillScript` types the input into bahn.de's form, `fetchScript` then fetches order + ticket PDFs
  inside the page; the page is only shown if bahn.de asks for more, e.g. a captcha),
  `TicketView` (full-screen barcode at full brightness, PDF, `AddToWalletButton`, "Zugbindung aufgehoben"),
  `TicketButton` (next to "Gespeichert" in `JourneyDetailView`, only once the journey has tickets), `AddTicketButton` ("Via Ticket hinzufügen" icon next to "Verbindungen suchen", opens `TicketLookupView`), `TicketsListView` (Settings → Gespeicherte Tickets, list + delete; also "Zeitkarten": passes like the Deutschland-Ticket added from a screenshot via `PhotosPicker`, shown in `TravelPassView` with `AddToWalletButton`),
  `SeatReservationViews` (`ReservationRow` in `LegCard` above "Mehr", read-only). Reservations come from the journey's
  tickets (`AppModel.reservations(for:)`) and only show on the leg whose train matches.
- `Features/Trips/TripsView.swift` – upcoming/past saved journeys, `SaveJourneyButton`.
- `Features/Traewelling/` – `CheckinSheet`, `TraewellingLoginButton`.
- `Features/Sharing/` – preview of `betterbahn://share` links and imported DB shares.
- `Features/Settings/` – settings (incl. privacy policy link and "not affiliated with DB" note), `BC100RulesView`, quick tags.
- `Shared/DesignSystem.swift` – reusable UI pieces (`Card`, `SectionHeader`, `LineBadge`, `TimeStack`,
  `DelayPill`, `PlatformBadge`, `InfoChip`, `Color.brand`, …). Reuse these instead of new styling.
- `Shared/StationPicker.swift` (`StationInput`, `TimeSelector`), `LocationService`, `PreviewData`.
- `Shared/DebugScreens.swift` (DEBUG only) – launch args: `-debugScreen <name>`,
  `-seedDemoTrips YES`, `-seedStressTrips <count>`.

## BetterBahnKit (`Packages/BetterBahnKit/Sources/BetterBahnKit/`)

- `Models/` – `Journey` → `Leg` → `Stopover`, `Line`, `Product`, `TimeInfo` (planned/actual),
  `PlatformInfo`, `Trip`, `JourneyPage`; `Station` (+ `DataSource`, `Coordinate`); `BoardEntry`;
  `TrainMessage` (DB delay reasons/notices); `RideMatch`.
- `Transit/TransitProvider.swift` – `TransitProvider` protocol (`searchStations`, `journeys`,
  `board`, `trip`) and `JourneyQuery`.
- `Transit/CombinedProvider.swift` – what the app uses: primary `TransitousProvider`, optional
  fallback (none configured), cooldown health check, `BahnDeClient`, `BahnExpertClient`, `BahnJetztClient`.
- `Transit/BahnDe/` – bahn.de web API via the `Cloudflare/bahnde-proxy` Worker (same endpoints/headers as Travel::Status::DE::DBRIS):
  station-search fallback, coach sequence → series/Tz/Taufname (`TrainModel`, `TrainsetNames`) and the
  full Wagenreihung (`CoachSequence`: coaches, classes, amenities, sectors, direction; also DB Regio RE/RB via
  `sequenceReference`),
  board + `fahrt` → `JourneyStop`s for Zusatzhalte (`inserting`, `nextRegularStop`) and platforms Transitous lacks
  (`fillingMissingPlatforms`, e.g. Hamburg Hbf; saved journeys via `JourneyRefresher`, which also applies the names below), and bahn.de's
  own train names for boards (departures and arrivals) and journey legs (`correctingTrainNames`, e.g. "RJ 171" that Transitous calls "ICE 171"). Responses are
  cached; a 403/429 pauses all bahn.de requests for 10 min (`BahnDeGate`).
- `Transit/BahnExpert/` – bahn.expert, only as fallback for the train type (`TrainTypeLookup`) when bahn.de
  has no coach sequence: it has DB's planned formation (`DB-plan`) for days ahead; bahn.de is only asked
  for departures within `BahnDeClient.formationLookahead` (12 h).
- `Transit/BahnJetzt/` – live train positions from bahn.jetzt's `/api/journeys` (one shared list,
  refreshed by `AppModel.followTrainPositions()` while the map is on screen). Long-distance trains by
  number, regional/S-Bahn by run number (`Line.tripNumber`).
- `Transit/Transitous/` – MOTIS API client + DTOs (`M*` types). Station-name cleanup and
  deduplication of boards happen here.
- `Transit/Timetables/` – official DB Timetables XML client (realtime overrides, messages), through the
  `bahnde-proxy` Worker, which holds the API key. The app only uses it where App Attest works. A train not
  found at a station's EVA is looked for at its other levels (`/station` `meta`, e.g. "Hamburg Hbf (S-Bahn)").
- Logic: `JourneyReplanner`, `ConnectionCheck` (`ConnectionIssue`, `JourneyRefresher`), `PlatformChange`
  (platform changes since the last refresh → push, ignores sectors/bus bays), `TrainRoutePlanner`,
  `ViaRoutePlanner` (vias without minimum stay keep a through train as one leg), `TrainPicker`, `TicketFilter`/`BC100Rules`, `BoardFilter`.
- `Traewelling/` – OAuth PKCE (`TraewellingAuth`, `TokenStore`), `TraewellingClient`
  (check-ins, history), `QuickTag`.
- `Tickets/` – DB tickets by order number: `DBOrder` reads bahn.de's order JSON into `DBTicket`s (one per
  "Leistungsbündel"; partner tickets like Eurostar only noted; reservation-only bookings without a ticket become
  `DBTicket`s with `isReservationOnly`), `DBOrderPage` (page URL, fill/error/fetch scripts, result),
  `SeatReservation` (Wagen/Platz, matched to a leg by train name/number), `TicketBarcodeReader` (PDFKit + Vision: the Aztec's original bytes from the PDF – Vision's `payloadData` is
  Aztec's internal encoding, the ISO-8859-1 string is the message), `WalletPassPayload` + `WalletPassClient`,
  `UICBarcode` (UIC "#UT" barcode → FCB 3 via a minimal unaligned-PER reader: issuing date, travellers, first
  open ticket/pass and its validity; the issuer's signature is checked by the pass signer, which answers 422 →
  `WalletPassError.unverifiedBarcode`), `TravelPass` ("Zeitkarte" read from such a barcode, only its bytes are kept; a Deutschland-Ticket valid
  longer than a month counts as a BahnCard 100's; `WalletPassPayload(pass:)` shows the validity as from → until). Passes are stored like tickets (`TicketStore`, `passes.json`).
  bahn.de's bot protection blocks the order API outside its page in a real browser (403), so there is no direct client.
- `Sharing/` – `JourneyShareLink` (betterbahn://share encoding), `DBShare` + `DBShareImporter`
  (parse DB Navigator/bahn.de shared text, resolve via `betterbahn://import`).
- `Geometry/` – polyline decode, `RouteGeometryService`, `SegmentHeatmap`.
- `Support/HTTPClient.swift` – shared HTTP + `TransitError`, `JSONDecoding`. `ProductStyle` colors.
- `Support/WorkerAuth.swift` – App Attest for BetterBahn's own Workers: attests the device key once, then
  gets hourly access tokens (`X-BetterBahn-Token`); `HTTPClient.sendRaw(_:auth:)` adds the token and retries
  once after a 401. Clients use `WorkerAuth.shared` only on the real `URLSession.shared` (tests' mocked
  sessions get none). Server side: `Cloudflare/shared/appattest.mjs`.

## Build & test

- **Kit tests** (Swift Testing, network mocked via `URLProtocol` + `Tests/.../Fixtures/*.json`):
  ```bash
  Packages/BetterBahnKit/swift-test.sh --package-path Packages/BetterBahnKit
  ```
  Use the wrapper (temp `--scratch-path`); plain `swift test` can fail codesigning because of
  extended attributes in `.build`. Add `--filter <Name>` to run a subset.
- **App build only – never run iOS Simulator tests** (per CLAUDE.md):
  ```bash
  xcodebuild -project BetterBahn.xcodeproj -scheme BetterBahn -destination 'generic/platform=iOS Simulator' build -quiet
  ```
- `BetterBahn/`, `BetterBahnWidgets/` and `BetterBahnShare/` are synchronized folders in `project.pbxproj`:
  new files there join their target automatically.

## Conventions

- Put logic and models in BetterBahnKit (testable, `Sendable`, `public`); keep views thin.
- Add a Kit test for behaviour changes; mock HTTP with a `URLProtocol` subclass like existing tests.
- German, plain user-facing wording; DB-style station names (e.g. "Frankfurt (Oder)", "Bernau (bei Berlin)").
- Commit titles: short imperative sentence ("Show …", "Stop …", "Keep …"), add `(fixes #N)` only
  when an issue is really fixed. No Claude co-author trailer.
- Main branch is `prod`; work happens on version branches like `v0.1`.
