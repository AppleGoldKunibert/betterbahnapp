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
| `BetterBahn/` | App target (UI + app state). Default actor isolation is **MainActor** (hence `nonisolated` on some types). |
| `BetterBahnWidgets/` | Widget extension: `TripLiveActivity` (Lock Screen / Dynamic Island). |
| `BetterBahnShare/` | Share extension: `ShareViewController` takes shared DB text/URL and opens `betterbahn://import?...`. |
| `Packages/BetterBahnKit/` | Local SwiftPM package with all models, networking and logic (iOS 26 + macOS 26, everything `Sendable`). Tests live here. |
| `Config/` | xcconfigs + Info.plists. `Signing.xcconfig` holds team ID; optional gitignored `Local.xcconfig` overrides it. |
| `Cloudflare/` | Worker that bounces the Träwelling OAuth callback to `betterbahn://oauth` (see its README). |
| `Cloudflare/bahnde-proxy/` | Separate Worker (`betterbahn2`) proxying bahn.de's web API (`/web/api/…` paths), because bahn.de blocks Apple's URL loading stack (see its README). `BahnDeClient.baseURL` points at it. |
| `docs/transit-providers.md` | Why Transitous is the primary data source and fallback options. |

Targets/schemes: `BetterBahn`, `BetterBahnWidgetsExtension`, `BetterBahnShareExtension`, `BetterBahnKit`.
Bundle IDs: `de.goldkunibert.BetterBahn[.Widgets|.Share]`. URL scheme: `betterbahn://`.

## App target (`BetterBahn/`)

- `App/BetterBahnApp.swift` – `@main`, `AppDelegate` (registers BG task for ending Live
  Activities), `RootView` with 4 tabs: Verbindungen (`ConnectionsView`), Karte (`TravelMapView`),
  Abfahrten (`StationBoardView`), Einstellungen (`SettingsView`). Handles `onOpenURL`
  (`DBShare.text(fromAppURL:)` → `ImportedJourneyView`, `JourneyShareLink` → `SharedJourneyPreviewView`)
  and scene-phase refresh start/stop.
- `App/AppModel.swift` – the single `@Observable` app state, injected via `.environment(model)`.
  Owns `CombinedProvider`, `TraewellingClient`, helpers (`TrainPicker`, `JourneyReplanner`,
  `DBShareImporter`, `TrainRoutePlanner`, `TicketFilter`, `TimetablesClient`, `JourneyRefresher`),
  persisted lists (favorites, recents, `savedJourneys`, `traewellingTrips`, tracked manual check-ins),
  realtime refresh loops (journeys every 300 s; train positions only while the map is shown, every 15 s or 60 s on mobile data/Low Data Mode), delay notifications,
  geometry/heatmap caches, Live Activity selection. Also defines `SavedJourney`, `PlanVersion`,
  `ImportedTrip`, `RecentSearch`, `Storage`, `AppSettings`, `ConnectionNotifier`.
- **Persistence:** `Storage.save/load(key:)` writes JSON to `Application Support/BetterBahn/<key>.json`
  (migrates from old UserDefaults). `AppSettings` uses UserDefaults directly. Saved data must stay
  decodable across versions (e.g. `DataSource.dbRest` kept only for decoding).
- `App/LiveActivityManager.swift` – ActivityKit wrapper; attributes in Kit `TripActivityAttributes`.
- `Features/Connections/` – search form (`ConnectionsView`, `ConnectionSearch`, `RouteOptionsEditor`
  for via stops/products/max transfers), `JourneyResultsView` (+ `JourneyCard`, `TrainNumberSheet`),
  `JourneyDetailView` (+ `LegCard`, `TransferRow`, alternatives sheets), `JourneyMapView` (MapKit),
  `JourneyReplanSheet` (replan from mid-journey).
- `Features/Departures/` – `StationBoardView`/`BoardRow`, `TripView` (single train's stops).
- `Features/Map/` – `TravelMapView` heatmap of past trips (`TravelMapHeatmap`, railway tile overlay).
- `Features/Trips/TripsView.swift` – upcoming/past saved journeys, `SaveJourneyButton`.
- `Features/Traewelling/` – `CheckinSheet`, `TraewellingLoginButton`.
- `Features/Sharing/` – preview of `betterbahn://share` links and imported DB shares.
- `Features/Settings/` – settings, `BC100RulesView`, quick tags.
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
  station-search fallback, coach sequence → series/Tz/Taufname (`TrainModel`, `TrainsetNames`),
  board + `fahrt` → `JourneyStop`s for Zusatzhalte (`inserting`, `nextRegularStop`). Responses are
  cached; a 403/429 pauses all bahn.de requests for 10 min (`BahnDeGate`).
- `Transit/BahnExpert/` – bahn.expert, only as fallback for the train type (`TrainTypeLookup`) when bahn.de
  has no coach sequence: it has DB's planned formation (`DB-plan`) for days ahead; bahn.de is only asked
  for departures within `BahnDeClient.formationLookahead` (12 h).
- `Transit/BahnJetzt/` – live train positions from bahn.jetzt's `/api/journeys` (one shared list,
  refreshed by `AppModel.followTrainPositions()` while the map is on screen).
- `Transit/Transitous/` – MOTIS API client + DTOs (`M*` types). Station-name cleanup and
  deduplication of boards happen here.
- `Transit/Timetables/` – official DB Timetables XML client (realtime overrides, messages).
  `DefaultCredentials.swift` is **gitignored**; copy from `.template`.
- Logic: `JourneyReplanner`, `ConnectionCheck` (`ConnectionIssue`, `JourneyRefresher`),
  `TrainRoutePlanner`, `ViaRoutePlanner`, `TrainPicker`, `TicketFilter`/`BC100Rules`, `BoardFilter`.
- `Traewelling/` – OAuth PKCE (`TraewellingAuth`, `TokenStore`), `TraewellingClient`
  (check-ins, history), `QuickTag`.
- `Sharing/` – `JourneyShareLink` (betterbahn://share encoding), `DBShare` + `DBShareImporter`
  (parse DB Navigator/bahn.de shared text, resolve via `betterbahn://import`).
- `Geometry/` – polyline decode, `RouteGeometryService`, `SegmentHeatmap`.
- `Support/HTTPClient.swift` – shared HTTP + `TransitError`, `JSONDecoding`. `ProductStyle` colors.

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
- New Swift files must be added to the right target in `project.pbxproj`.

## Conventions

- Put logic and models in BetterBahnKit (testable, `Sendable`, `public`); keep views thin.
- Add a Kit test for behaviour changes; mock HTTP with a `URLProtocol` subclass like existing tests.
- German, plain user-facing wording; DB-style station names (e.g. "Frankfurt (Oder)", "Bernau (bei Berlin)").
- Commit titles: short imperative sentence ("Show …", "Stop …", "Keep …"), add `(fixes #N)` only
  when an issue is really fixed. No Claude co-author trailer.
- Main branch is `prod`; work happens on version branches like `v0.1`.
