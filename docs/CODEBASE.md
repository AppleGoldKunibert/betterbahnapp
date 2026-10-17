# BetterBahn – codebase guide

Map of the code. Don't read it whole: grep for the feature or type you change and read that part, then open
only the files you change. Keep it current when structure changes. Build, test and branch rules:
`.claude/CLAUDE.md`.

## Layout

| Path | Contents |
| --- | --- |
| `BetterBahn/` | App target (UI + app state). Default isolation **MainActor** (hence `nonisolated` on some types). `PrivacyInfo.xcprivacy` declares required-reason APIs (UserDefaults); keep it current. |
| `BetterBahnWidgets/` | `TripLiveActivity` (Lock Screen / Dynamic Island); `JourneyOverviewWidget` ("Reiseübersicht", small/medium, timer target via `JourneyWidgetIntent`); `CurrentTrainWidget` ("Aktueller Zug": next stops, delays, exit). `LiveTrainWidgets.swift`: "Live-Geschwindigkeit" (home + lock screen) and "Live-Position" (`MKMapSnapshotter`) fetch the ridden train (`JourneyWidgetState.ridingLeg`) from bahn.jetzt, fall back to the app's stored position, else next stop + timer; `RefreshLiveWidgetIntent` reloads, tap opens `TrainMapLink`. All read the `WidgetSnapshot` from App Group `group.de.goldkunibert.BetterBahn` (Info.plist key `BetterBahnAppGroup`). |
| `BetterBahnShare/` | `ShareViewController`: shared DB text/URL → `betterbahn://import?...`. |
| `Packages/BetterBahnKit/` | Models, networking, logic (iOS 26 + macOS 26, all `Sendable`) and tests. |
| `Config/` | xcconfigs, Info.plists, entitlements. `Signing.xcconfig` holds the team ID; gitignored `Local.xcconfig` overrides it. |
| `Cloudflare/` | Worker `betterbahn` (`wrangler.toml`): Träwelling OAuth bounce to `betterbahn://oauth`, privacy policy `/datenschutz`, support page `/support`, short links (`/share`, `/s/<id>`, `apple-app-site-association`, KV 30 days, App Attest + rate limit). |
| `Cloudflare/bahnde-proxy/` | Worker `betterbahn2`: DB Timetables (`/timetables/v1/…`, API key as secret) and App Attest tokens (`/auth/…`). Its bahn.de paths (`/web/api/…`) are refused by bahn.de since October 2026. `BahnDeClient.baseURL`, `TimetablesClient.baseURL`. |
| `Server/bahnde-proxy/` | Docker server (Python, curl_cffi) asking bahn.de with a browser's TLS fingerprint, which Akamai demands and Workers can't make (#342): the Worker's `/web/api/…` paths and App Attest tokens, cache, rate limit, pause after a block. The app asks it first (`BahnDeProxy.baseURL`; game-server host behind Tailscale Funnel, `panel_boot.py`; bahn.de refuses Oracle Cloud). `python3 -m unittest Server/bahnde-proxy/proxy_test.py`. |
| `Cloudflare/pass-signer/` | Worker `betterbahn-pass`: signs Wallet passes for DB tickets (Pass Type ID certificate as secrets). Needs App Attest, only UIC `#UT` barcodes whose issuer signature verifies (`uicsignature.mjs`). `npm install && npm test`. |
| `Cloudflare/stats/` | Worker `betterbahn-stats` (D1) answering `POST /train-stats` (#316): per train number and stop the delays, cancellations and platform moves of 30 days, one row per train and day (`schema.sql`, `train_days`). Filled daily by `importer.py` from piebro/deutsche-bahn-data (CC BY 4.0; Action `train-stats-import.yml`), so nothing asks bahn.de and the app reports nothing (#336). `node --test Cloudflare/stats/worker.test.mjs`, `python3 -m unittest Cloudflare/stats/importer_test.py`. |
| `Cloudflare/checkin-push/` | Worker `betterbahn-push` (D1, cron every minute): own read-only Träwelling login per device (AES-GCM), checks the dashboard every 2 min, sends APNs pushes (`followedStatusID`). `node --test Cloudflare/checkin-push/worker.test.mjs`. |
| `Cloudflare/shared/` | `appattest.mjs`: App Attest verification and the `X-BetterBahn-Token` the Workers check. `node --test Cloudflare/shared/appattest.test.mjs`. |
| `.github/workflows/` | `pr-build.yml` (macOS: Kit tests + unsigned app build on code PRs), `pr-secrets.yml` (gitleaks + guard against `DefaultCredentials.swift`), `sync-prod.yml` (merges prod into every branch but `appstorerelease`), `train-stats-import.yml` (daily, into D1), `monthly-data-update.yml` (1st of the month: rebuilds the three station lists, PR into prod on `monthlyupdate-<MM>/<YY>`; `scripts/check-data-update.py` stops it when a list is empty or 10 % smaller; the PR gets no CI by itself, push an empty commit). |
| `scripts/` | `make-station-hints.py` (offline search hints), `make-ril100.py` (`Ril100.swift`, also DB's XLSX for codes abroad, needs `openpyxl`), `make-station-names.py` (`StationNames.swift` from OpenStation NeTEx, DB RIS names via bahn.expert and Transitous; run after `make-ril100.py`; `--refresh` re-asks bahn.expert, ~1 h), `check-data-update.py`. `searchsim/`: Linux package (`./sync.sh`, `swift test`; `swift run SearchSim scenarios.txt` runs ~1150 live station-search scenarios, rerun after changing search ranking). |
| `docs/` | `transit-providers.md` (data sources), `app-review-notes.md` (App Store checklist and review notes). |

Targets: `BetterBahn`, `BetterBahnWidgetsExtension`, `BetterBahnShareExtension`, `BetterBahnKit`. Bundle IDs
`de.goldkunibert.BetterBahn[.Widgets|.Share]`, URL scheme `betterbahn://`. The app folders are synchronized folders
in `project.pbxproj`: new files join their target automatically.

## App target (`BetterBahn/`)

- `App/BetterBahnApp.swift` – `@main`, `AppDelegate` (BG tasks for ending Live Activities and for followed
  check-ins; tapped check-in notification → `AppModel.openFollowedCheckin`), `RootView` with 4 tabs: Verbindungen
  (`ConnectionsView`), Karte (`TravelMapView`), Abfahrten (`StationBoardView`), Einstellungen (`SettingsView`).
  `onOpenURL`: `DBShare.text(fromAppURL:)` → `ImportedJourneyView`; `JourneyShareLink` → `SharedJourneyPreviewView`
  (short links via `ShortShareLinkClient`, also Universal Links); `LiveActivityLink` (Live Activity, journey widget) →
  saved journey via `AppModel.journeyToOpen`; `TrainMapLink` → `LiveTrainMapView`. Scene-phase refresh start/stop.
- `App/AppModel.swift` – the single `@Observable` app state (`.environment(model)`). Owns `CombinedProvider`,
  `TraewellingClient`, `TrainPicker`, `JourneyReplanner`, `DBShareImporter`, `TrainRoutePlanner`, `TicketFilter`,
  `TimetablesClient`, `JourneyRefresher`; persisted lists (favorites, recents, `savedJourneys`, `traewellingTrips`,
  tracked manual check-ins); refresh loops: journeys every 300 s, the Live Activity's journey per
  `LiveActivityRefreshSchedule` (2 min, 1 min around arrivals and while transferring), train positions only while
  a map shows (Kit `TrainPositionRefresh`: 15 s, 60 s on mobile data/Low Data Mode, "Aus" loads once); delay
  notifications, geometry/heatmap caches, Live Activity selection. Defines `SavedJourney`, `PlanVersion`,
  `ImportedTrip`, `RecentSearch`, `Storage`, `AppSettings`, `ConnectionNotifier`. `SavedJourney.formations` keeps
  the Tz/Taufname seen per leg (`Leg.formationKey`, `rememberFormation`, used by `TrainFormationLabel`/`TrainSeriesTag`).
- **Persistence:** `Storage.save/load(key:)` → `Application Support/BetterBahn/<key>.json` (migrates old
  UserDefaults); `AppSettings` uses UserDefaults. Saved data must stay decodable across versions (e.g.
  `DataSource.dbRest` kept only for decoding).
- `App/CloudSync.swift` – iCloud KV mirror: favorites, recents and saved journeys per item via `CloudList` (Kit
  `SyncedList`: newest change per item wins, removals kept as dates); `AppSettings` as one snapshot, newer wins.
  Träwelling token via iCloud Keychain (`TokenStore`); a 401 retries with a token another device refreshed.
- `App/TicketStore.swift` – `SavedTicket` (`DBTicket` + its `SavedJourney.id`), only on this device in
  `Application Support/BetterBahn/Tickets/` (list + PDFs, file protection, **not** synced). `importTickets` matches
  a saved journey or imports the booking via `DBShareImporter.journey(from:)`.
- `App/LiveActivityManager.swift` – ActivityKit wrapper; attributes in Kit `TripActivityAttributes`.
- `App/WidgetSync.swift` – `updateWidgets()` (from `syncLiveActivity`, on position changes, forced on background)
  writes the `WidgetSnapshot` for `widgetJourney` (`liveJourneyCandidate`, else the next saved journey not switched
  off) and reloads widgets only on change.
- `Features/Connections/` – `ConnectionsView`, `ConnectionSearch`, `RouteOptionsEditor` (vias, products, max
  transfers), `JourneyResultsView` + `JourneyCard`, `TrainNumberSheet` ("Bestimmten Zug wählen", #225: trains fitting
  the input via Kit `TrainCandidateFinder`; picking one shows its stops in `TripContent` with boarding/exit preselected
  and pins that run; "Ein- und Ausstieg selbst angeben"), `JourneyDetailView` (+ `LegCard`, `TransferRow`,
  alternatives sheets), `JourneyMapView`, `JourneyReplanSheet` (replan mid-journey; "Halt hinzufügen" via
  `ManualStopSheet` adds an off-timetable exit, a check-in then becomes a manual trip via
  `AppModel.replaceCheckinWithManualTrip`; a new exit on the last train asks "Reise … beenden" / "Weiter nach …").
- `Features/Departures/` – `StationBoardView`/`BoardRow`, `TripView`. `CoachSequenceView.swift`: the Wagenreihung
  unfolds in place, no sheet. `CoachSequenceDisclosure` (row in `LegCard` and `TripContent`'s header) uses bahn.de's
  sequence, else vagonweb's plan, opens by itself 30 min before to 15 min after departure
  (`CoachSequence.unfoldsByItself`) or by tap; tapping a stop's platform in `TripContent` unfolds that stop's.
  `CoachSequencePanel`: notes (debug builds only: grey "bahn.de: …" line from `BahnDeClient.coachSequenceNote(for:)`,
  for the server's pause also `BahnDeGate.blockDescription`), one `TrainCard` per series (`TrainFormation.partsBySeries`,
  "2× ICE 4") with "BR …", each Tz with Taufname and the series' side view `Assets.xcassets/Trains/Train-<BR>` (401,
  402, 403, 407, 408, 411, 412; © DB AG, "Quelle: Deutsche Bahn", picked by Kit `TrainDrawing`).
  `CoachSequenceDiagram`: horizontal platform opening at the train's front, sector bar, part labels sticking to the
  visible edge (`onScrollGeometryChange`), `CoachTile`s to scale, "← Richtung".
- `Features/TrainSearch/` – `TrainSearchOverlay` (#183): Spotlight-style bar over every tab
  (`AppModel.showsTrainSearch`, from the train button on Verbindungen and the map's search button), searches while
  typing, day behind a calendar button, filtered by `AppSettings.trainSearchKinds` (all but "Sonstiges" by default)
  and `trainSearchCountries` (Germany), both synced. `TrainSearchResultView`: "Zugdetails anzeigen" (`TripView`),
  Wagenreihung (next stop; `CoachSequenceByStop` unfolds a list of the other stops, `BahnDeClient.formationStops(of:)`;
  a train not running starts at its first stop), "Auf Karte zeigen" (only while bahn.jetzt has a position).
- `Features/Map/` – `TravelMapView` heatmap of past trips (`TravelMapHeatmap`; `RailwayTileOverlay`: OpenRailwayMap,
  512 px, disk cache 7 days, 10-min pause after 403/429). A ride both saved and checked in is drawn from the check-in
  (`RideMatch.uncovered`). `YearReviewView` (#319, "Jahresrückblick", only via `YearReviewBanner` on Verbindungen in
  December and January): swipeable 9:16 cards from Kit `YearReview` (`AppModel.yearReview(for:)`, same
  `TravelMapSelection` and cached heatmap, km from cached geometry, series from `rememberedFormation`), shared as an
  image (`ImageRenderer`, heatmap card via `Canvas`). `LiveTrainMapView`: one train live on its track
  (`AppModel.geometry(for:)`, never straight lines), opened from `LiveTrainIconTile`; `JourneyMapView` shows running
  trains too.
- `Features/Tickets/` – `TicketLookupView` (bahn.de's "Auftragssuche" in a hidden SwiftUI `WebView`:
  `DBOrderPage.fillScript` fills the form, `fetchScript` fetches order + PDFs inside the page; shown only when bahn.de
  asks for more, e.g. a captcha), `TicketView` (full-brightness barcode, PDF, `AddToWalletButton`, "Zugbindung
  aufgehoben"), `TicketButton` (in `JourneyDetailView` once the journey has tickets), `AddTicketButton`,
  `TicketsListView` (Settings → Gespeicherte Tickets; "Zeitkarten" like the Deutschland-Ticket from a screenshot via
  `PhotosPicker`, `TravelPassView`), `SeatReservationViews` (`ReservationRow` in `LegCard`;
  `AppModel.reservations(for:)`, only on the leg whose train matches).
- `Features/Trips/TripsView.swift` – upcoming/past journeys, `SaveJourneyButton` (warns "Zug ist
  reservierungspflichtig" via `AppModel.reservationRequiredLegs`; ticket/reservation imports never warn).
- `Features/Traewelling/` – `CheckinSheet` (`MenuPickerRow` with constant width; keyboard hides on submit and only
  returns on `TraewellingError.isInvalidInput`; `.collision` offers "Trotzdem einchecken", `CheckinDraft.force`),
  `TraewellingLoginButton`, `CustomEmojiViews` (`EmojiMessageField`, `EmojiText`), `CheckinDetailSheet` ("Check-in
  ansehen" for check-ins made in the app, `AppModel.checkinStatusIDs`: edit text/visibility/trip type/tags, delete,
  "Mitreisende"), `CheckoutPrompt` (removing a journey with check-ins: check out at the last stop reached via
  `TraewellingClient.earlyExit`, delete them, or keep them).
  `FollowedCheckinsSection` (#196): who the user follows is checked in now, above "Deine Reisen"
  (`AppModel.followedCheckins`, every 2 min while Verbindungen shows, `keepFollowedCheckinsFresh`; one entry per person
  via `TraewellingClient.grouped`). Detail: train (`LegTripSheet`, hidden for manual trips), map with live position
  (tap → `LiveTrainMapView`), Träwelling link, like button (`likes_enabled` and `isLikable`). Track/train cached per
  status (`AppModel.followedTracks`/`followedTrains`); custom emojis of the author's instance
  (`User.mastodonServer`, else zug.network) via `AppModel.emojis(forTextOf:)`/`followedEmojis`.
  Push for new followed check-ins (#266, Settings → Träwelling, per device, off by default, only logged in): turning
  it on asks to confirm, `AppModel.enableFollowedCheckinPush` gets the APNs token (`didRegisterForPush`) and runs a
  second read-only login (Kit `FollowedCheckinPush.config`) for the `betterbahn-push` Worker; the app's own login
  can't be shared (access tokens last an hour, refresh tokens work once). `FollowedCheckinPushSubscription` is kept
  current by `syncFollowedCheckinPush()` at start (404 → setting off, `followedCheckinPushEnded`), ended on
  off/logout; a tap opens `followedCheckinToOpen`.
- `Features/PassengerRights/PassengerRightsViews.swift` – Fahrgastrechte (#311): `PassengerRightsBadge` in the lists,
  `PassengerRightsCard` in details ("Anspruch auf 25/50 % Entschädigung", "Antrag vorbereiten" →
  `PassengerRightsRequestSheet` with DB's form fields, copy buttons, link). `AppModel.passengerRightsClaim(for:)` feeds
  Kit `PassengerRights` (journey, earlier plans, tickets, BahnCard 100 setting); `notifyPassengerRights` notifies once
  per level after arrival and keeps the worst claim in `SavedJourney.recordedClaim`. Never shows amounts.
- `Features/Sharing/` – shared-journey and DB-share previews; `JourneyShareButton` (short link, falls back to the long
  one, `UIActivityViewController`).
- `Features/Settings/` – settings (privacy link, "not affiliated with DB"), `DataSourcesView` (every source with its
  attribution/license; keep current when adding one), `BC100RulesView`, quick tags.
- `Shared/DesignSystem.swift` – `Card`, `SectionHeader`, `LineBadge`, `TimeStack`, `DelayPill`, `PlatformBadge`,
  `InfoChip`, `OperatorLabel`, `Color.brand`, `.transition(.fold)` …; reuse these instead of new styling.
- `Shared/StationPicker.swift` (`StationInput`, `TimeSelector`), `LocationService`, `PreviewData`, `VagonwebBrowser`.
  `Shared/DebugScreens.swift` (DEBUG): `-debugScreen <name>`, `-seedDemoTrips YES`, `-seedStressTrips <count>`.

## BetterBahnKit (`Packages/BetterBahnKit/Sources/BetterBahnKit/`)

### Models

- `Journey` → `Leg` → `Stopover`, `Line`, `Product`, `TimeInfo` (planned/actual), `PlatformInfo`, `Trip`,
  `JourneyPage`, `Station` (+ `DataSource`, `Coordinate`), `BoardEntry`, `TrainMessage` (DB delay reasons/notices),
  `RideMatch`, `YearReview` (km, hours, punctuality < 6 min, series, stations, routes, countries from EVA/IFOPT).
- `StationNames` (#205) – `Station.displayName`: DB's name for German stations, the national railway's with accents
  abroad, from `Resources/StationNames.json` (OpenStation with DHID/EVA, names from DB RIS via bahn.expert's
  `stopPlace/byTerm`). Matched by the DHID in the stop ID ("de:08135:0620" = "de:08135:620"), EVA, `aliases` (non-German
  feeds' train stops within 300 m, matched within 150 m; German feeds get none, those can be trams), same name within
  600 m (`nameWords`: "…bahnhof"/"…bf" stem), brackets-only difference within 300 m unless they name a mode or border
  point, a part of it within 150 m; abroad `StationNames.folded` within 3 km. Only the shown name changes: `id`/`name`
  stay the feed's. Headsigns: `MPlace.displayName(ofHeadsign:)`, else `StationNames.displayName(forName:)`.
  `Station.displayName(for:)` shortens "hlavní nádraží"/"hlavná stanica". `StationNames.preload()` at launch.
  `StationNames.evaNumber(for:)` (stations with a single EVA only) is used by `BahnDeClient.evaNumber(for:)` before
  bahn.de's search, so statistics, Timetables and Wagenreihung don't ask bahn.de per stop.
- `OperatorBrand` (#166) – feed agency → EVU logo (`Assets.xcassets/Operators/Operator-<brand>`, `OperatorLabel`,
  light plate in dark mode if `needsPlateInDarkMode`; named DB S-Bahns show the "S", other "DB Regio AG …" the DB Regio
  logo), `OperatorBrand.displayName` ("ODEG", "Transdev"). International trains: `BahnDeClient.trainOperators(for:)`
  → `[TrainOperator]` from each stop's `adminID` (UIC code), shown by `TrainOperatorsLabel` (`OperatorLogo`) and at
  handover stops (`operatorStops(for:)`); the feed only names one.
- `Models/TripLap.swift` – `Trip.lap(at:near:arriving:)`: Transitous' trip for a ring line (S41/S42) is the vehicle's
  whole day (S42: 490 stops), so stops looked up by station hit the first lap. Cuts out one lap (needs a station
  visited ≥ 3 times); applied in `TripView.load()`, `CombinedProvider.trip(for:)` and "Zug vorgeben"
  (`TrainCandidateFinder.candidate`, `TrainCandidate.addingLaps`; `TrainRoutePlanner` rides the visit at
  `TrainRequirement.departure`, #355). `extraBefore`/`extraAfter`, `Trip.hasPreviousLap`/`hasNextLap` → "Vorherige /
  Nächste Runde laden". `Support/LoadedLaps.swift` (`AppModel.loadedLaps`, `loadedLaps.json`, forgotten after 15 min
  unless saved). `coveringUntil` adds laps until a leg's destination; `JourneyRefresher.apply` never snaps a
  destination to a visit before the leg's own stops.

### Transit

- `Transit/TransitProvider.swift` – `TransitProvider` (`searchStations`, `journeys`, `board`, `trip`), `JourneyQuery`.
- `Transit/CombinedProvider.swift` – what the app uses: `TransitousProvider` (no fallback configured), cooldown
  health check, `BahnDeClient`, `VagonwebClient`, `BahnExpertClient`, `BahnJetztClient`.
- `Transit/StationSearch.swift` (#90) – shortcuts "b" (bus), "t" (tram), "l" (nearest first) as a separate word.
  Without "b", bus-only stops are left out of the picker unless nothing else matches;
  `TransitousProvider.searchStations(_:near:)` passes modes to the geocoder and filters after
  `mergingNearbyDuplicates`. Plain `searchStations(String)` (share import etc.) keeps every stop.
- `Transit/Ril100.swift` (#165) – codes from `Resources/Ril100.json` (DB InfraGO "Betriebsstellen", Mobilithek, CC BY
  4.0). A typed code ("ff") puts its station first (`searchStations(_ search:near:)`) and drops duplicates; matched by
  position and name (`matches`), shortest code shown, option `AppSettings.ril100Enabled`. Abroad (X + country letter,
  Z for eastern Europe, from DB's XLSX) entries have no positions (`Entry.isAbroad`): matched by `exactNameKey`, or
  `looseNameKey` inside `countryBounds`; position beats name. `Ril100.preload()` and `Ril100.codes(for:)` run off the
  main thread (#301). A typed code's plain search gets `extraQueryDeadline`, so it can't hit `CombinedProvider`'s 2.5 s.
- `Transit/Transitous/` – MOTIS client + `M*` DTOs, station-name cleanup, board dedup. Departures add arrivals going
  on as "Nur Ausstieg" (`continuingWithoutBoarding`, #105). Search ranking `searchRank`: text match vs. nearness/size;
  also asks "<nearby town> <query>" (`NearbyTowns`, offline, so coordinates never leave the device), nearby stations
  from `StationHints` (`Resources/StationHints.json`), aliases ("ber" → Flughafen BER), German names abroad
  (`germanNames`; "prag" places CZPTT's station first via `namedStations`/`placingNamedStation`). Bus stops' exact
  names only count nearby; far stops abroad only as train stations in the typed place. `isLocalName` ("süd" in Essen),
  `joiningWords` ("an der"/"am"); extra "<q> Hbf"/"<q> Bahnhof" queries for short input; `withMainStationName`;
  DELFI border points ("Kehl(Gr)") dropped.
  Coupled trains (ICE 940 / 950) show as one: `Line.coupledTrains`, `displayName`; same number under another brand is
  one train (`Line.isSameTrain(as:)`, `Leg.directionDescription`). Boards: `combiningCoupledTrains`; legs:
  `coupledTrains(for:)` (3 s in `CombinedProvider.journeys`, again in `JourneyRefresher.refresh`). Wagenreihung covers
  both (`FormationRequest.coupledNumbers`); check-in asks which train (`Leg.riding(_:)`); `CoupledTrain.tripId` and
  `Line.runs(ownDirection:ownTripId:)` switch between the trains' stops.
- `Transit/Transitous/CzechPlatforms.swift` – planned Czech platforms for feeds without any there (DELFI's ICE/IC
  Berlin–Praha, alex, copies): the first Czech stop (`isCzechStop`) as CZPTT's station via `v1/map/stops`, the train by
  number ±5 min, tracks via `v5/trip`, cached 12 h. Only where missing, `PlatformInfo.source == .czechTimetable` →
  info dot, `PlannedPlatformNote`. Applied in `CombinedProvider.journeys`, `CombinedProvider.trip(for:)`,
  `JourneyRefresher.refresh`.
- `Transit/Transitous/TwinTrainStops.swift` – stops/platforms a long-distance train's own feed leaves out (ÖBB's RJ
  177; `mayLackStops`): taken from the same train in another feed on the leg's start board (`insertingMissingStops`,
  cached 12 h), shared stops take DB's names. Runs before the Czech platforms; journey view does both first
  (`completingStopsAndPlatforms`), then the live refresh.
- `Transit/BahnDe/` – bahn.de web API only via `Server/bahnde-proxy` (`BahnDeProxy`, #342; URLs built on the Worker's
  `baseURL` and mapped onto it; endpoints as Travel::Status::DE::DBRIS): station-search fallback, `TrainModel`,
  `TrainsetNames`, `CoachSequence` (coaches, classes, amenities, sectors, direction; RE/RB via `sequenceReference`),
  Zusatzhalte (`inserting`, `nextRegularStop`), `fillingMissingPlatforms` (e.g. Hamburg Hbf), `correctingTrainNames`
  ("RJ 171" Transitous calls "ICE 171"). Live times (`ezZeit`; `correctingFromBoard`, `applyingLiveTimes`,
  `applyingLiveTimes(from:to:)`) beat DELFI's forecasts, but not a delay/early time DB Timetables set (`keepingDelays`),
  and never turn 2+ min early into on time (`turnsEarlyIntoOnTime`). Responses cached. On failure the server is left
  alone (`BahnDeProxy.gate`: 10 min after 403/429/452, 2 min when down) and requests throw `rateLimited`, shown as
  "Plan-Wagenreihung · Aktuelle nicht verfügbar" / "Aktuelle Wagenreihung nicht verfügbar". No other way to bahn.de:
  the Worker and the phone's hidden browser were refused. `requiresReservation(for:)` (attribute `RP`, also other
  railways via `lookupReference`; shares the `journeyCourse` cache).
- `Transit/Vagonweb/` – vagonweb.cz (with permission, #95): planned compositions for the timetable year from the train's
  HTML (`VagonwebComposition.scheduled`, fixtures `vagonweb-ice*.html`), used when bahn.de has none: `AppModel.trainType`
  and "Plan-Wagenreihung" (`CoachSequence.source == .vagonweb`). Cloudflare bot check → hidden `WebPage`
  (`VagonwebBrowser`, `browserLoader`); first-visit gate (`VagonwebClient.isGate`) → `plannedCompositionsRequest`. Cached
  per train and year, logs under `vagonweb`. Turned round at `reversalStations`/`terminusStations` (along
  `FormationRequest.stopsBefore`). "Abweichende Wagenreihung" from `CoachSequence.deviations(fromPlan:)` (bahn.de's
  `sequenceStatus` is set for nearly every train). Country per railway (`VagonwebClient.countries(for:)`, ÖBB first
  for NJ/EN). `NJ`, `EN`, `IR` (`plannedCategories`, `BahnDeClient.plannedOnlyCategories`) are never asked of bahn.de (an
  unknown category's 403 pauses everything). Sections where the composition changes: `Section.covers`,
  `composition(…route:)`, `restricted(to:)`, `startsReversed`; trains running together ("RJX 184") left out. Parser
  reads vagonweb's HTML and a browser's serialized DOM; day restrictions per coach not read. Those trains' legs get
  only platforms from bahn.de (`BahnDeClient.takesOnlyPlatforms`).
- `Transit/BahnExpert/` – train type fallback (`TrainTypeLookup`, `DB-plan`) when bahn.de and vagonweb have none;
  bahn.de is only asked within `BahnDeClient.formationLookahead` (24 h). Needs `Referer` + non-curl UA (else empty
  206). Platforms bahn.de and Transitous lack (`ExpertPlatforms.swift`, `BahnExpertClient.fillingMissingPlatforms`):
  SBB/ÖBB stations of their EC/RJ(X), Nightjet, Euronight, InterRegio, on legs and trips (`TripView.insertZusatzhalte`),
  cached 30 min; for NJ/EN/IR they replace the feed's (`overwriting`). `TransferDisposition` ("Anschluss wartet
  (nicht)" in `TransferRow`) via `disposition(from:to:)`/`dispositions(in:now:)` (`dispositionStatus`, 15 min ago to
  3 h ahead, notifies once per `notificationID`). `ExpertTimes` (`liveTimes(category:number:day:)`, `ExpertTimesCache`
  2 min) referees bahn.de vs. DB Timetables in `applyingLiveTimes(…referee:)` (closer value wins, tie → Timetables).
- `Transit/TrainNumberSearch.swift` (#183) – bahn.expert's `journey/find` lists a number's runs (`TrainNumberQuery`,
  `ranked` by `TrainSearchFilter`/`TrainSearchCountry`), `detailsByJourneyId` their stops; `run(of:)` finds the run on
  a stop's board so the trip comes from Transitous.
- `Transit/TrainChoice.swift` (#225) – `TrainNameQuery` ("ICE 423", "RE 3 (3300)"; `score`; regional only by category
  or full run number), `TrainCandidateFinder` (actor): `numberTrains` (one bahn.expert request), `routeFit`, `ranked`,
  `candidate(for:)`; lines from up to 4 route boards (`routeCandidates`, `departuresForTrainLookup`, `prefetch`,
  failures not cached, `boardExtras`). `catchable`: trains leaving at most 2 min before the traveller is there, plus
  the 2 latest of the previous 30 min at the origin (`TrainRoutePlanner.plan(pickedEarlier:)`). Picked run pinned in
  `TrainRequirement.tripId`.
- `Transit/BahnJetzt/` – live positions from `/api/journeys` (`AppModel.followTrainPositions()` while a map shows);
  long-distance by number, regional/S-Bahn by `Line.tripNumber`.
- `Transit/Timetables/` – DB Timetables XML through `betterbahn2` (holds the key; only where App Attest works). Other
  station levels via `/station` `meta`; no requests for trains over 4 h ago (`changesMemory`); without live data no
  `actual` (no "+0"). Boards: `applyingRealtime(to:at:)` after bahn.de/Transitous (nothing changes without `fchg`).
  The Worker asks IRIS first, the API Marketplace only on failure (60/min). `infersOnTime` only within 2 h;
  `JourneyRefresher.droppingInferredOnTime` cleans older saves.

### Logic

- `JourneyReplanner` (`continuations`, `fastestFirst`), `ConnectionCheck` (`ConnectionIssue`), `PlatformChange` (push,
  ignores sectors/bus bays), `TrainRoutePlanner`, `ViaRoutePlanner` (vias without stay keep a through train as one
  leg), `TrainPicker` ("Anderer Zug": `replacing` + `MissedConnection` #226, `reroutes` "Andere Routenführung",
  `journeysIgnoringBoardingRules`, `journeysContinuingFromRestrictedTrains`, both added in `JourneyResultsView`),
  `StationCalls` (hides routes doubling back through origin/destination; not for vias), `TicketFilter`/`BC100Rules`,
  `BoardFilter`, `ManualStop` (`Stopover.manual`, `isManual` survives refreshes unlike `isAdditional`;
  `Trip.inserting(manualStop:boardingAt:)`).

### Träwelling, Mastodon

- `Traewelling/` – OAuth PKCE (`TraewellingAuth`, `TokenStore`), `TraewellingClient`, `QuickTag`. Finding the train
  asks the nearest stations' boards in parallel and caches autocomplete/departures (retries and
  `checkinAsManualTrip` don't search again, #106); checks in as soon as found, gives up after
  `TraewellingSearchBudget` (15 s, 45 s when the station search took > 3 s), then offers the manual trip (#289).
  Träwelling's board is MOTIS' next 50 departures within 200 m, so it also loads only the leg's kind
  (`travelType`, `boardTravelTypes`/`travelType(for:)`). `replaceWithManualTrip` (creates the trip, deletes, re-checks in).
  `TraewellingCheckinEdit`: `status(id:)`, `updateStatus`, `deleteStatus`, `tags`, `applyTagChanges`/`StatusTagChanges`,
  exit moves, `earlyExit`, `fellowTravellers(of:)` (`trips/{id}/statuses`). `FollowedCheckinPush`
  (`subscribe`/`update`/`unsubscribe`, App Attest). `TraewellingFollowed`: `followedCheckins()` (dashboard back 12 h,
  rides under way or leaving within 20 min, `checkedIn`), `like`/`unlike` (scope `write-likes`, 403 →
  `TraewellingError.likeNotAllowed`), `CombinedProvider.leg(forCheckin:)` (`hafasId` = Transitous trip ID, else the
  origin's board; `nil` for manual trips with a UUID). Token refreshes send no `scope`, so new scopes never break logins.
- `Mastodon/CustomEmoji.swift` (#168) – `CustomEmojiClient` (`/api/v1/custom_emojis` of the user's `mastodonUrl`, else
  zug.network, cached a day), `CustomEmojiText` (completion, ranking, splitting).

### Tickets, sharing, widgets, geometry

- `Tickets/` – `DBOrder` (order JSON → one `DBTicket` per "Leistungsbündel", partner tickets only noted,
  `isReservationOnly`), `DBOrderPage`, `SeatReservation` (matched to a leg by train), `TicketBarcodeReader` (PDFKit +
  Vision; take the Aztec's original bytes from the PDF, Vision's `payloadData` is the internal encoding),
  `WalletPassPayload` + `WalletPassClient`, `UICBarcode` (FCB 3 via a minimal unaligned-PER reader; signer answers 422
  → `WalletPassError.unverifiedBarcode`), `TravelPass` (Zeitkarte, only barcode bytes kept, `passes.json`). No direct
  order API client: bahn.de blocks it outside its page.
- `Tickets/PassengerRights.swift` (#311) – `PassengerRights.claim(for:earlierPlans:hasTicket:hasBahnCard100:)`: delay
  at the destination against the first booked plan (`previousVersions`), 25 % from 60 min, 50 % from 120; only with a
  ticket, BahnCard 100 or a long-distance train; `requestFields` for DB's form.
- `Sharing/` – `JourneyShareLink` (encoding, payload limits, short IDs), `ShortShareLinkClient` (long link as
  fallback), `DBShare` + `DBShareImporter` (DB Navigator/bahn.de shared text).
- `Widgets/` – `WidgetSnapshot` + `WidgetStore` (App Group JSON), `JourneyWidgetState` (phase, next stop and delay,
  transfer, countdown; `changeDates`), `WidgetTimer` (> 12 h reads "2d 3h 49m"), `TrainMapLink` (`betterbahn://map`).
- `Geometry/` – polyline decode, `RouteGeometryService`, `SegmentHeatmap`.

### Statistics, support

- `Statistics/TrainStatistics.swift` (#316) – `TrainStatistics` (30 days per stop: delays, cancellations, platform
  moves), `TrainStatisticsClient`, `TrainStatisticsStore` (cache per train and day; off with
  `AppSettings.showTrainStatistics`; EVA via `BahnDeClient.evaNumber(for:)`). Shown from `minimumRuns` (5); launch arg
  `-debugstats` enables `TrainStatistics.testMode` until the app is deleted (`enableTestModeIfRequested`: from 1 run,
  plus debug rows). Views in `TrainStatisticsViews.swift`: "Erfahrungswerte" (`LegCard` "Mehr", `TripContent`), tight
  transfer warning (`Journey.tightTransfers`, `TrainStatistics.Stop.transferOutlook`) in `TransferRow` and `JourneyCard`.
- `Support/HTTPClient.swift` – shared HTTP, `TransitError`, `JSONDecoding`; every request sends `identifyingUserAgent`
  (only `BahnDeClient` sends browser agents). `ProductStyle`: `Line.color` = product color, or `Line.lineColorHex`
  (S-/U-Bahn Berlin tables, #206), else `Line.feedColorHex` (Transitous `routeColor` if white text stays readable,
  #291); widgets/Live Activity use the product color. Night trains (`Line.isNightTrain`: `nightRail`, NJ/EN/UEx, night
  operators, `JourneyDetails.hasSleepingCars`, #241) get a bed (`Line.symbolName`, `isNightTrain` in widgets). Filter
  groups (`ProductChips`, board filter): `.highSpeed`, `.longDistance`, `.nightTrain`, `.interregio`; the last two are
  filter-only (`Line.product` stays `.longDistance`, filters compare `Line.filterProduct`); old searches upgraded via
  `Product.upgradingLegacySelection` (`hasProductGroups`).
- `Support/LoadingDeadline.swift` – waits up to 4 s for live data on a journey/run never loaded live, so it doesn't
  jump from timetable to delays. `Support/LiveDataCache.swift` – `AppModel.liveJourneys`/`liveTrips` (12 h, 50 each)
  show at once and refresh in the background; `AppModel.prepareLiveData` for the first search result.
- `Support/WorkerAuth.swift` – App Attest for own Workers: attests once, hourly `X-BetterBahn-Token`,
  `HTTPClient.sendRaw(_:auth:)` retries once after a 401; only on the real `URLSession.shared` (mocked tests get none).

## Tests and conventions

- Kit tests use Swift Testing with HTTP mocked by a `URLProtocol` subclass + `Tests/.../Fixtures/*.json`. Use
  `swift-test.sh` (temp `--scratch-path`): plain `swift test` can fail codesigning on `.build` attributes.
- Content folding in or out uses `.transition(.fold)`, never `.move(edge: .top)` (slides over the text above).
- DB-style station names ("Frankfurt (Oder)", "Bernau (bei Berlin)").
- Commit titles: short imperative sentence ("Show …", "Stop …", "Keep …").
