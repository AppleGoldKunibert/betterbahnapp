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
| `Cloudflare/` | Worker (`betterbahn`, `wrangler.toml`) that bounces the Träwelling OAuth callback to `betterbahn://oauth`, serves the privacy policy at `/datenschutz` (linked in Settings) and the support page at `/support`, and stores shared journeys for short links (`/share`, `/s/<id>` + `apple-app-site-association`, KV with 30-day TTL, App Attest + rate limit; see its README). |
| `Cloudflare/bahnde-proxy/` | Separate Worker (`betterbahn2`) proxying bahn.de's web API (`/web/api/…` paths), because bahn.de blocks Apple's URL loading stack, and DB Timetables (`/timetables/v1/…`, API key as Worker secret). Also hands out the App Attest tokens (`/auth/…`). See its README. `BahnDeClient.baseURL`, `TimetablesClient.baseURL` point at it. |
| `Cloudflare/pass-signer/` | Worker (`betterbahn-pass`) that signs Apple Wallet passes for DB tickets with the Pass Type ID certificate (secrets), since that can't ship in the app. Needs an App Attest token, and only signs UIC (`#UT`) barcodes whose issuer signature verifies against UIC's public key list (`uicsignature.mjs`). `npm install && npm test` (see its README). |
| `Cloudflare/shared/` | `appattest.mjs`: App Attest verification and the signed tokens both Workers check (`X-BetterBahn-Token`); `node --test Cloudflare/shared/appattest.test.mjs`. |
| `.github/workflows/` | GitHub Actions: `pr-build.yml` (macOS: Kit tests + unsigned app build on PRs touching code), `pr-secrets.yml` (Linux: gitleaks secret scan + guard against committing `DefaultCredentials.swift`), `sync-prod.yml` (merges prod into every other branch except `appstorerelease`). |
| `scripts/` | `make-station-hints.py`: rebuilds BetterBahnKit's offline station list for search (see Transitous below). `searchsim/`: Linux package that copies the platform-neutral Kit sources in (`./sync.sh`), so `swift test` runs `BetterBahnKitTests.swift` without a Mac and `swift run SearchSim scenarios.txt` runs the real station search against live Transitous for ~1150 place/query scenarios (rerun after changing search ranking). |
| `docs/transit-providers.md` | Why Transitous is the primary data source and fallback options. |
| `docs/app-review-notes.md` | App Store submission checklist (privacy URL, App Privacy, demo access) and review notes. |

Targets/schemes: `BetterBahn`, `BetterBahnWidgetsExtension`, `BetterBahnShareExtension`, `BetterBahnKit`.
Bundle IDs: `de.goldkunibert.BetterBahn[.Widgets|.Share]`. URL scheme: `betterbahn://`.

## App target (`BetterBahn/`)

- `App/BetterBahnApp.swift` – `@main`, `AppDelegate` (registers BG task for ending Live
  Activities), `RootView` with 4 tabs: Verbindungen (`ConnectionsView`), Karte (`TravelMapView`),
  Abfahrten (`StationBoardView`), Einstellungen (`SettingsView`). Handles `onOpenURL`
  (`DBShare.text(fromAppURL:)` → `ImportedJourneyView`, `JourneyShareLink` → `SharedJourneyPreviewView` (short links via
  `ShortShareLinkClient`, also as Universal Links), `LiveActivityLink` from tapping the Live Activity → that saved
  journey via `AppModel.journeyToOpen` on the Verbindungen tab)
  and scene-phase refresh start/stop.
- `App/AppModel.swift` – the single `@Observable` app state, injected via `.environment(model)`.
  Owns `CombinedProvider`, `TraewellingClient`, helpers (`TrainPicker`, `JourneyReplanner`,
  `DBShareImporter`, `TrainRoutePlanner`, `TicketFilter`, `TimetablesClient`, `JourneyRefresher`),
  persisted lists (favorites, recents, `savedJourneys`, `traewellingTrips`, tracked manual check-ins),
  realtime refresh loops (journeys every 300 s, the Live Activity's journey per `LiveActivityRefreshSchedule` – 2 min, ±1 min around arrivals, 1 min while transferring; train positions only while a map is shown, at the interval picked in Settings → Live-Karte, Kit `TrainPositionRefresh`: automatic = 15 s, 60 s on mobile data/Low Data Mode; "Aus" loads once), delay notifications,
  geometry/heatmap caches, Live Activity selection. Also defines `SavedJourney`, `PlanVersion`,
  `ImportedTrip`, `RecentSearch`, `Storage`, `AppSettings`, `ConnectionNotifier`.
  `SavedJourney.formations` remembers the Tz/Taufname seen per leg (`Leg.formationKey`), so they stay
  known (and synced) after the journey (`rememberFormation`, used by `TrainFormationLabel`/`TrainSeriesTag`).
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
  `CoachSequenceView` (Wagenreihung sheet, opened from `CoachSequenceButton` in train headers or a stop's platform in `TripContent`;
  bahn.de's sequence, else vagonweb's planned one).
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
- `Features/Sharing/` – preview of shared journeys and imported DB shares; `JourneyShareButton` (in `JourneyDetailView`)
  uploads for a short link, falls back to the long link, and opens `UIActivityViewController`.
- `Features/Settings/` – settings (incl. privacy policy link and "not affiliated with DB" note), `DataSourcesView`
  (Datenquellen: every service with its attribution/license links; keep it current when adding a source), `BC100RulesView`, quick tags.
- `Shared/DesignSystem.swift` – reusable UI pieces (`Card`, `SectionHeader`, `LineBadge`, `TimeStack`,
  `DelayPill`, `PlatformBadge`, `InfoChip`, `Color.brand`, …). Reuse these instead of new styling.
- `Shared/StationPicker.swift` (`StationInput`, `TimeSelector`), `LocationService`, `PreviewData`, `VagonwebBrowser`.
- `Shared/DebugScreens.swift` (DEBUG only) – launch args: `-debugScreen <name>`,
  `-seedDemoTrips YES`, `-seedStressTrips <count>`.

## BetterBahnKit (`Packages/BetterBahnKit/Sources/BetterBahnKit/`)

- `Models/` – `Journey` → `Leg` → `Stopover`, `Line`, `Product`, `TimeInfo` (planned/actual),
  `PlatformInfo`, `Trip`, `JourneyPage`; `Station` (+ `DataSource`, `Coordinate`); `BoardEntry`;
  `TrainMessage` (DB delay reasons/notices); `RideMatch`.
- `Transit/TransitProvider.swift` – `TransitProvider` protocol (`searchStations`, `journeys`,
  `board`, `trip`) and `JourneyQuery`.
- `Transit/StationSearch.swift` – station-field shortcuts (#90): "b" bus stops, "t" tram stops, "l" nearest
  first, as a separate word before or after the name. Without "b", bus-only stops are left out of the
  picker's search (unless nothing else matches); `TransitousProvider.searchStations(_:near:)` with a
  `StationSearch` passes the modes to the geocoder and filters after `mergingNearbyDuplicates` (which unions modes).
  The plain `searchStations(String)` (share import etc.) keeps every stop.
- `Transit/CombinedProvider.swift` – what the app uses: primary `TransitousProvider`, optional
  fallback (none configured), cooldown health check, `BahnDeClient`, `VagonwebClient`, `BahnExpertClient`, `BahnJetztClient`.
- `Transit/BahnDe/` – bahn.de web API via the `Cloudflare/bahnde-proxy` Worker (same endpoints/headers as Travel::Status::DE::DBRIS):
  station-search fallback, coach sequence → series/Tz/Taufname (`TrainModel`, `TrainsetNames`) and the
  full Wagenreihung (`CoachSequence`: coaches, classes, amenities, sectors, direction; also DB Regio RE/RB via
  `sequenceReference`),
  board + `fahrt` → `JourneyStop`s for Zusatzhalte (`inserting`, `nextRegularStop`) and platforms Transitous lacks
  (`fillingMissingPlatforms`, e.g. Hamburg Hbf; saved journeys via `JourneyRefresher`, which also applies the names below), and bahn.de's
  own train names for boards (departures and arrivals) and journey legs (`correctingTrainNames`, e.g. "RJ 171" that Transitous calls "ICE 171"). Responses are
  cached; a 403/429 pauses all bahn.de requests for 10 min (`BahnDeGate`).
- `Transit/Vagonweb/` – vagonweb.cz (used with their permission, #95): scheduled train compositions for the
  whole timetable year, read from the train's HTML page (`VagonwebComposition.scheduled`, fixtures
  `vagonweb-ice*.html`). Used when bahn.de has no coach sequence: the train type (`AppModel.trainType`) and the
  planned Wagenreihung without platform positions (`CoachSequence.source == .vagonweb`, "Plan-Wagenreihung").
  vagonweb sits behind Cloudflare's bot check; when it answers instead of the page, the app loads it in a hidden
  `WebPage` (`VagonwebBrowser`, passed in as `browserLoader`). On a first visit vagonweb shows only an "anzeigen" link
  (`VagonwebClient.isGate`); then the compositions come from `ajax_dalsi_razeni_vlak.php` (`plannedCompositionsRequest`).
  Pages are cached per train and timetable year; logs under the `vagonweb` category.
  vagonweb draws a train as it leaves its first station; the plan is turned round after each change of direction
  up to the stop (`reversalStations` from vagonweb's note plus `VagonwebClient.terminusStations`, counted along
  `FormationRequest.stopsBefore` or the leg's trip). bahn.de's `sequenceStatus` ("DIFFERS_FROM_SCHEDULE") is set for
  nearly every train, so "Abweichende Wagenreihung" comes from `CoachSequence.deviations(fromPlan:)` (missing/extra
  coaches, class changes; order ignored) against vagonweb's plan.
- `Transit/BahnExpert/` – bahn.expert, only as fallback for the train type (`TrainTypeLookup`) when bahn.de
  has no coach sequence and vagonweb has none either: it has DB's planned formation (`DB-plan`) for days
  ahead; bahn.de is only asked for departures within `BahnDeClient.formationLookahead` (12 h).
- `Transit/BahnJetzt/` – live train positions from bahn.jetzt's `/api/journeys` (one shared list,
  refreshed by `AppModel.followTrainPositions()` while the map is on screen). Long-distance trains by
  number, regional/S-Bahn by run number (`Line.tripNumber`).
- `Transit/Transitous/` – MOTIS API client + DTOs (`M*` types). Station-name cleanup and
  deduplication of boards happen here. MOTIS leaves trains nobody may board out of departures, so a departure
  board also asks for arrivals and adds the ones going on as "Nur Ausstieg" (`continuingWithoutBoarding`, #105). Station search ranking is `searchRank`; with the user's location
  it balances text match against nearness and size and also asks for "<nearby town> <query>"
  (`NearbyTowns`, an offline list, so coordinates never leave the device), nearby stations starting
  with what was typed (`StationHints`, from `Resources/StationHints.json`, built by
  `scripts/make-station-hints.py`; only names, rerun now and then for new stations; big ones from
  anywhere, for longer names only the two nearest starting with them) and aliases like "ber" → "Flughafen
  BER". German names of towns abroad ("stettin", "prag", `germanNames`) match and ask for the local name.
  A bus stop's exact name only counts nearby, and stops abroad far away only for a train station in the
  place that was typed (train stations abroad within 100 km count like German ones). In the user's town a
  station's short name is exact ("süd" in Essen, `isLocalName`). "Hbf"/"Bahnhof" and parts of town only
  count next to a word matching the stop; "an der"/"am" inside a typed town name don't count at all
  (`joiningWords`). Up to 3 letters it also asks for "<q> Hbf"/"<q> Bahnhof", for
  a single longer word "<q> Hbf" (kept only in that town) and "<q> Bahnhof" (Kurort Rathen, Sylt). Main
  stations get their own name back (`withMainStationName`: not "KA Hbf (Vorplatz)"), DELFI's border
  points ("Kehl(Gr)") are dropped.
  Coupled trains under two numbers (ICE 940 + 950 Berlin–Hamm) show as
  one (`Line.coupledTrains` with each train's direction, `displayName` "ICE 940 / 950"; the same number under
  another brand, e.g. ÖBB's "RJ 177" and DB's "ICE 177", is one train, not a pair: `Line.isSameTrain(as:)`,
  `Leg.directionDescription`): board rows by same time/platform/destination (`combiningCoupledTrains`), journey
  legs by `coupledTrains(for:)` (same arrival at the destination, checked against the other train's departure at
  the origin; called from `CombinedProvider.journeys` with a 3 s deadline, and again from `JourneyRefresher.refresh`
  for legs the search had no time for). Their Wagenreihung/Tz include both halves
  (`FormationRequest.coupledNumbers`), each part labelled with its train, destination and Tz; a Träwelling
  check-in asks which train you sit in (`Leg.riding(_:)`). `CoupledTrain.tripId` lets `TripView`/`LegTripSheet`
  switch between the trains' own stops (`Line.runs(ownDirection:ownTripId:)`).
- `Transit/Timetables/` – official DB Timetables XML client (realtime overrides, messages), through the
  `bahnde-proxy` Worker, which holds the API key. The app only uses it where App Attest works. A train not
  found at a station's EVA is looked for at its other levels (`/station` `meta`, e.g. "Hamburg Hbf (S-Bahn)").
  Trains that ran over 4 hours ago aren't asked about (`changesMemory`): DB has dropped their changes and
  would report them on time. Without live data a time has no `actual`, so no delay shows (not "+0").
  A stop DB schedules without a change only counts as on time when the train runs within 2 h
  (`infersOnTime`); a journey tomorrow shows plain times, and `JourneyRefresher.droppingInferredOnTime` clears
  such made-up "pünktlich" from journeys saved earlier.
- Logic: `JourneyReplanner`, `ConnectionCheck` (`ConnectionIssue`, `JourneyRefresher`), `PlatformChange`
  (platform changes since the last refresh → push, ignores sectors/bus bays), `TrainRoutePlanner`,
  `ViaRoutePlanner` (vias without minimum stay keep a through train as one leg), `TrainPicker` (also
  `journeysIgnoringBoardingRules`: direct trains with "Nur Ein-/Ausstieg" for the expert option of that name,
  added to search results in `JourneyResultsView`), `StationCalls` (hides routes that change onto a train also calling at
  the origin, or leave one also calling at the destination – e.g. Berlin Hbf → Halle → back via Hbf; not for via searches), `TicketFilter`/`BC100Rules`, `BoardFilter`.
- `Traewelling/` – OAuth PKCE (`TraewellingAuth`, `TokenStore`), `TraewellingClient`
  (check-ins, history), `QuickTag`. Finding the train asks only the nearest few stations' departures, in parallel
  (12 s timeout), and caches autocomplete/departures, so retries and "Manuell eintragen" (`checkinAsManualTrip`) don't search again (#106).
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
- `Sharing/` – `JourneyShareLink` (betterbahn://share encoding, payload limits, short-link IDs),
  `ShortShareLinkClient` (`/share` on the `betterbahn` Worker, long link as fallback), `DBShare` + `DBShareImporter`
  (parse DB Navigator/bahn.de shared text, resolve via `betterbahn://import`).
- `Geometry/` – polyline decode, `RouteGeometryService`, `SegmentHeatmap`.
- `Support/HTTPClient.swift` – shared HTTP + `TransitError`, `JSONDecoding`. Every request sends `identifyingUserAgent` (app version + `/support` contact, as Transitous/OpenRailwayMap/Träwelling ask); only `BahnDeClient` sends browser agents. `ProductStyle` colors.
- `Support/LoadingDeadline.swift` – waits up to 4 s for live data before a screen shows a journey or train
  run never loaded live before (journey detail, `TripView`, `LegTripSheet`), so it doesn't show the timetable
  first and jump to the delays. `Support/LiveDataCache.swift` – what was seen live (`AppModel.liveJourneys`,
  `liveTrips`, on disk as `liveJourneys.json`/`liveTrips.json`, 12 h, 50 each) shows at once and refreshes in the
  background; saved journeys count as seen. Search results prepare the first connection's live data
  (`AppModel.prepareLiveData`).
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
