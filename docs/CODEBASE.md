# BetterBahn – codebase guide

Map of the code. Don't read it whole: grep for the feature or type you change and read that part, then open
only the files you change. Keep it current when structure changes. Build, test and branch rules:
`.claude/CLAUDE.md`.

## Layout

| Path | Contents |
| --- | --- |
| `BetterBahn/` | App target (UI + app state). Default isolation **MainActor** (hence `nonisolated` on some types). `PrivacyInfo.xcprivacy` declares required-reason APIs (UserDefaults); keep it current. |
| `BetterBahnWidgets/` | `TripLiveActivity` (Lock Screen / Dynamic Island); `JourneyOverviewWidget` ("Reiseübersicht", small/medium, timer target via `JourneyWidgetIntent`); `CurrentTrainWidget` ("Aktueller Zug": next stops, delays, exit). `LiveTrainWidgets.swift`: "Live-Geschwindigkeit" (home + lock screen) and "Live-Position" (`MKMapSnapshotter`) fetch the ridden train (`JourneyWidgetState.ridingLeg`) from bahn.jetzt, fall back to the app's stored position, else next stop + timer; `RefreshLiveWidgetIntent` reloads, tap opens `TrainMapLink`; on tinted/clear Home Screens (`widgetRenderingMode != .fullColor`) the position widget draws `RouteSketch` (track + train from `MapRoute`) instead of the map tiles, which flatten to a blot there. `StationBoardWidget.swift` ("Abfahrten", #314, small/medium/large + lock screen): the next departures of a station picked in the widget's settings (`StationBoardWidgetIntent`: `StationEntity` from the favourites, `onlyToDestination` toggle + `RouteDestinationEntity` for a commuter route – then the next connections there with arrival and changes; the toggle because the widget editor can't clear a picked station –, `BoardWidgetProducts` filter; rows per family via `ViewThatFits`); fetches Transitous itself (`StationBoardProvider`, no bahn.de: no Worker auth in the extension), timeline entries at each departure (Kit `BoardWidgetRows`), reload after 20 min; tap opens `BoardWidgetLink` (the board, or the route in the search). All read the `WidgetSnapshot` (and `WidgetStations`) from App Group `group.de.goldkunibert.BetterBahn` (Info.plist key `BetterBahnAppGroup`). |
| `BetterBahnShare/` | `ShareViewController`: shared DB text/URL → `betterbahn://import?...`. |
| `Packages/BetterBahnKit/` | Models, networking, logic (iOS 26 + macOS 26, all `Sendable`) and tests. |
| `Config/` | xcconfigs, Info.plists, entitlements. `Signing.xcconfig` holds the team ID; gitignored `Local.xcconfig` overrides it. |
| `Cloudflare/` | Worker `betterbahn` (`wrangler.toml`): Träwelling OAuth bounce to `betterbahn://oauth`, privacy policy `/datenschutz`, support page `/support`, short links (`/share`, `/s/<id>`, `apple-app-site-association`, KV 30 days, App Attest + rate limit). "Ankunft teilen" (#317, `arrival.mjs`): with the last train attached, `/s/<id>` is a pickup page (arrival, delay, platform, stops), live from IRIS per stop, else bahn.de's `fahrt` via `Server/bahnde-proxy` (refusals logged as `arrival upstream`), refreshing via `/share/<id>/live`; such links expire 2 h after the arrival. |
| `Cloudflare/bahnde-proxy/` | Worker `betterbahn2`: DB Timetables (`/timetables/v1/…`, API key as secret) and App Attest tokens (`/auth/…`). Its bahn.de paths (`/web/api/…`) are refused by bahn.de since October 2026. `BahnDeClient.baseURL`, `TimetablesClient.baseURL`. |
| `Server/bahnde-proxy/` | Docker server (Python, curl_cffi) asking bahn.de with a browser's TLS fingerprint, which Akamai demands and Workers can't make (#342): the Worker's `/web/api/…` paths and App Attest tokens, cache, rate limit, requests to bahn.de spaced `MIN_INTERVAL` apart, pause after a block (a new session; requests running on the old one finish there, #411). The app asks it first (`BahnDeProxy.baseURL`; game-server host behind Tailscale Funnel, `panel_boot.py`; bahn.de refuses Oracle Cloud). `python3 -m unittest Server/bahnde-proxy/proxy_test.py`. |
| `Cloudflare/pass-signer/` | Worker `betterbahn-pass`: signs Wallet passes for DB tickets (Pass Type ID certificate as secrets). Needs App Attest, only UIC `#UT` barcodes whose issuer signature verifies (`uicsignature.mjs`). `npm install && npm test`. |
| `Cloudflare/stats/` | Worker `betterbahn-stats` (D1) answering `POST /train-stats` (#316): per train number and stop the delays, cancellations and platform moves of 30 days, one row per train and day (`schema.sql`, `train_days`). Filled daily by `importer.py` from piebro/deutsche-bahn-data (CC BY 4.0; Action `train-stats-import.yml`), so nothing asks bahn.de and the app reports nothing (#336). `node --test Cloudflare/stats/worker.test.mjs`, `python3 -m unittest Cloudflare/stats/importer_test.py`. |
| `Cloudflare/checkin-push/` | Worker `betterbahn-push` (D1, cron every minute): own read-only Träwelling login per device (AES-GCM), checks the dashboard every 2 min, sends APNs pushes (`followedStatusID`). `node --test Cloudflare/checkin-push/worker.test.mjs`. |
| `Cloudflare/live-activity/` | Worker `betterbahn-live` (D1, cron every minute): keeps the Live Activity current while the app is closed (#315). The app hands over the activity's push token and the journey (Kit `LiveActivityPushJourney`) when it goes to the background (`PUT /activities/<id>`) and takes it back when opened (`DELETE`). On `LiveActivityRefreshSchedule`'s times it asks DB's keyless IRIS about the current train (`iris.mjs`: `plan` once per stop, then `fchg`), works out the state like `ContentState.from` (`state.mjs`, checked against the Kit fixture `live-activity-push.json`) and pushes it when it changed; ends the activity after the arrival. `node --test Cloudflare/live-activity/worker.test.mjs`. |
| `Cloudflare/shared/` | `appattest.mjs`: App Attest verification and the `X-BetterBahn-Token` the Workers check. `node --test Cloudflare/shared/appattest.test.mjs`. `apns.mjs`: APNs with the provider token (`betterbahn-push`, `betterbahn-live`). |
| `.github/workflows/` | `pr-build.yml` (macOS: Kit tests + unsigned app build on code PRs), `pr-secrets.yml` (gitleaks + guard against `DefaultCredentials.swift`), `sync-prod.yml` (merges prod into every branch but `appstorerelease`), `train-stats-import.yml` (daily, into D1), `monthly-data-update.yml` (1st of the month: rebuilds the three station lists and `Platforms.json`, PR into prod on `monthlyupdate-<MM>/<YY>`; `scripts/check-data-update.py` stops it when a list is empty or 10 % smaller; the PR gets no CI by itself, push an empty commit). |
| `scripts/` | `make-station-hints.py` (offline search hints), `make-ril100.py` (`Ril100.swift`, also DB's XLSX for codes abroad, needs `openpyxl`), `make-station-names.py` (`StationNames.swift` from OpenStation NeTEx, DB RIS names via bahn.expert and Transitous; run after `make-ril100.py`; `--refresh` re-asks bahn.expert, ~1 h), `make-big-stations.py` (`Models/BigStations.swift`: price class 1 and 2 from OpenStation NeTEx, run after `make-station-names.py`), `check-data-update.py`, `make-exit-sides.py` (#394: `ExitSides.json`, which side of the track each platform is on, from OpenStreetMap: `--pbf germany-latest.osm.pbf` reads Geofabrik's extract with pyosmium in four passes, else Overpass tile by tile with a cache, which often answers 502; run on a Mac, both are blocked from cloud sessions. A platform edge takes the track it touches on its level, a platform the track numbered like it or the only one next to it; S-Bahn tracks are `light_rail`; tests `python3 scripts/make-exit-sides-test.py`), `make-platforms.py` (`Platforms.json` for the coach advice, #383: tracks sharing a platform and lifts from OpenStation, platform edges/areas (also multipolygons), stairs, lifts, sector signs, buffer stops and tracks above ground (termini: no track runs on past the buffer stops) from OSM's Germany extract via pyosmium, `pip install osmium`, ~7 min; ODbL), `make-seat-maps.py` (ICE seat maps from DB's Wagenreihungspläne via bahn.expert `/WRSheets/<sheet>.pdf`: images in `Assets.xcassets/SeatMaps/`, seat positions in `SeatMaps.json`; needs poppler, Pillow, numpy). `searchsim/`: Linux package (`./sync.sh`, `swift test`; `swift run SearchSim scenarios.txt` runs ~1150 live station-search scenarios, rerun after changing search ranking). |
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
  saved journey via `AppModel.journeyToOpen`; `TrainMapLink` → `LiveTrainMapView`; `BoardWidgetLink` → the Abfahrten
  tab (`AppModel.boardStationToOpen`) or the route search on Verbindungen (`AppModel.searchToOpen`). All links go
  through `RootView.open(_:)`, also Spotlight results (`CSSearchableItemActionType`, `AppModel.linkToOpen`). Scene-phase
  refresh start/stop.
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
- `App/LiveActivityManager.swift` – ActivityKit wrapper; attributes in Kit `TripActivityAttributes`; `alert` lights up the running activity (only the
  `ActivityAttributes` conformance is iOS-only, so Kit tests cover `ContentState.from`). With Settings → Meine Reisen
  "Live-Aktivität über Server aktualisieren" (`AppSettings.liveActivityServerUpdates`, on by default) activities start
  with a push token; `AppModel.handOverLiveActivity()` gives it and the journey to `Cloudflare/live-activity` when the
  app goes to the background and after the background refresh, `takeBackLiveActivity()` ends that when it is active (#315).
- `App/ExitReminders.swift` – exit reminders (#313, Settings → Meine Reisen, per journey `exitRemindersOff`): Kit `Journey.exitReminders` → time-sensitive notifications `exit|<entry>|<leg>`, rescheduled after every refresh, one per stop (per-device log `exitReminderDates`); while the Live Activity runs, its alert instead. The text names the exit side ("Fulda, Ausstieg links", `ExitSides.side(leaving:)`, #394) when known.
- `App/CalendarEvents.swift` – calendar events of saved journeys (#382): `CalendarButton` (`Features/Trips/`, next to
  the share button in `JourneyDetailView`) adds one from Kit `JourneyCalendarEvent`, tapped again deletes it
  (`removeFromCalendar`, full access only); the first time it asks for
  `AppSettings.calendarAccess` (per device, Settings → Kalender). `.full`: `scheduleCalendarSync` (after every
  `savedJourneys` change and on becoming active) updates the events, removes those of deleted journeys and forgets
  ones deleted in the calendar. `.addOnly` (iOS write-only access) writes once. Event IDs are kept per device either
  way (`calendarEventIDs`, `CalendarEventLog`), so switching to full access later keeps the earlier events current.
  The event's link opens the journey by `SavedJourney.id`. With full access `CalendarChoiceRow` (Settings → Kalender) picks
  the calendar for new events (`AppSettings.calendarID`, per device, nil = default); events already added stay put.
  "Automatisch" (`AppSettings.calendarAutoAdd`, Kit `CalendarAutoAdd`: off by default, at departure or on
  saving, per device) adds due journeys in the sync, each once (`CalendarAutoAddLog`, also set by a manual add), so an
  event deleted in the calendar doesn't come back; access is only asked when the setting is switched on.
- `App/WidgetSync.swift` – `updateWidgets()` (from `syncLiveActivity`, on position changes, forced on background)
  writes the `WidgetSnapshot` for `widgetJourney` (`liveJourneyCandidate`, else the next saved journey not switched
  off) and reloads the journey widgets (`WidgetStore.journeyWidgetKinds`) only on change. `updateWidgetStations()` (on
  every change of favourites/recent searches) writes `WidgetStations` for the board widget's settings.
- `App/SpotlightSync.swift` – favourite stations and saved journeys in the iOS search (#387): Kit `SpotlightEntry`
  builds title, subtitle, keywords (RIL100 codes, train numbers), expiry (journey's end) and the deep link, which is
  also the item's ID (`BoardWidgetLink` board, `LiveActivityLink` journey). `scheduleSpotlightSync()` (on every
  change of the favourites or saved journeys, also from iCloud, and when the app comes to the foreground) indexes
  them with their App Intents entities (`FavoriteStationEntity`, `SavedJourneyEntity`, `IndexedEntity`, queries via
  `AppDependencyManager`) and removes what's gone (IDs in UserDefaults `spotlightIDs`). Tapping opens the link via
  the entity's `OpenIntent` (`AppModel.linkToOpen`) or the `CSSearchableItemActionType` activity.
- `Features/Connections/` – `ConnectionsView`, `ConnectionSearch`, `RouteOptionsEditor` (vias, products, max
  transfers), `JourneyResultsView` + `JourneyCard`, `TrainNumberSheet` ("Bestimmten Zug wählen", #225: trains fitting
  the input via Kit `TrainCandidateFinder`; picking one shows its stops in `TripContent` with boarding/exit preselected
  and pins that run; "Ein- und Ausstieg selbst angeben"), `JourneyDetailView` (+ `LegCard`, `TransferRow`,
  alternatives sheets; below the legs `CO2SavingButton` "−42 kg CO₂" → `CO2Sheet`, #386, from Kit `CO2Comparison`
  with the legs' cached track geometry; `WeatherLabel` "☀ 18° bei Ankunft" under the destination (summary card and the
  last leg) and "beim Umstieg" under a transfer station with more than 15 min to the next train
  (`JourneyWeather.arrival(of:in:)`), tap → `WeatherDetails` popover with rain, wind and
  the Open-Meteo credit, #385, `WeatherViews.swift`, off with `AppSettings.showWeather`), `JourneyMapView`, `JourneyReplanSheet` (replan mid-journey; "Halt hinzufügen" via
  `ManualStopSheet` adds an off-timetable exit, a check-in then becomes a manual trip via
  `AppModel.replaceCheckinWithManualTrip`; a new exit on the last train asks "Reise … beenden" / "Weiter nach …").
- `Features/Departures/` – `StationBoardView`/`BoardRow`, `TripView` (and `LegTripSheet`, the read-only run of a journey's
  leg): `plainTrip` with the board's line and lap, then `AppModel.liveRun` with the shown or remembered trip (and the
  saved leg) as baseline, painted as the sources answer, remembered via `rememberLive`. `DelayTimeText` shows a delay
  in planned-time mode only with a live time (no "0" for a plain timetable). `CoachSequenceView.swift`: the Wagenreihung
  unfolds in place, no sheet. `CoachSequenceDisclosure` (row in `LegCard` and `TripContent`'s header) uses bahn.de's
  sequence, else vagonweb's plan, opens by itself 30 min before to 15 min after departure
  (`CoachSequence.unfoldsByItself`) or by tap; tapping a stop's platform in `TripContent` unfolds that stop's. A leg's
  shows the stop the train just left until it would close (`CoachSequence.shownAfterDeparture`, 15 min), then the next
  one, on the last stretch to a terminus the last one it left, until the arrival; where bahn.de has none, one of the two
  stops before (asked again after `formationMaxAge`), so the marked coaches stay (`BahnDeClient.formationRequests(for:)`).
  `CoachSequencePanel`: notes (debug builds only: grey "bahn.de: …" line from `BahnDeClient.coachSequenceNote(for:)`,
  for the server's pause also `BahnDeGate.blockDescription`), one `TrainCard` per series (`TrainFormation.partsBySeries`,
  "2× ICE 4") with "BR …", each Tz with Taufname and the series' side view `Assets.xcassets/Trains/Train-<BR>` (401,
  402, 403, 407, 408, 411, 412; © DB AG, "Quelle: Deutsche Bahn", picked by Kit `TrainDrawing`).
  `CoachSequenceDiagram`: horizontal platform opening at the train's front, sector bar, part labels sticking to the
  visible edge (`onScrollGeometryChange`), `CoachTile`s to scale, "← Richtung".
  Tapping an ICE coach (bahn.de's sequence only) opens `SeatMapSheet` (`SeatMapView.swift`, #365): the coaches from
  above in the diagram's order, each turned round when its trainset stands with the higher numbers on the left
  (`SeatMap.isTurned`), seat numbers drawn on top and the pictograms (`SeatMap.icons`) drawn again from the unturned
  drawing, so both stay upright; the leg's reserved seat highlighted. Coach advice (#383): `CoachTile.suggested`
  (dashed frame) for `CoachSequence.coachIDs(for:)`, `CoachAdvice.legend` below (not for the exit, `notesCoachAdvice`,
  as the card says it right below); `CoachAdviceLabel` in `TransferRow`
  (its own full-width line, without the station) and, for the exit, in the last `LegCard` (`JourneyDetailView.loadCoachAdvice`, `AppModel.coachAdvice(for:)`).
  Saving your own seat (#410): `SaveSeatButton` at the end of the "Wagenreihung" row (`CoachSequenceDisclosure(savesSeat:)`,
  only without a reservation, from 15 min before the departure until the arrival) opens a sheet with the coaches
  (`CoachSequence.seatCoachNumbers`) and an optional seat; the saved seat is passed on like a reservation
  (`SeatReservation(_: SavedSeat)`: coach highlighted, seat in the seat map) and counts as one for the coach advice.
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
- `Features/Collection/` – `CollectionView` (#384, "Sammlung", `CollectionButton` next to "Vergangene Fahrten" on
  Verbindungen): progress per category, `CollectionCategoryView` grid (not collected greyed out), sheet with the first and
  all rides. Kit `TravelCollection` from the travel map's rides (`AppModel.travelCollection()`); trains only from
  `rememberedFormation`, so Träwelling check-ins count only for stations. "Neu" badges: IDs collected since the last
  visit (`newCollectionIDs`, UserDefaults `collectionSeenIDs`, the first computation is the starting point).
- `Features/Tickets/` – `TicketLookupView` (bahn.de's "Auftragssuche" in a hidden SwiftUI `WebView`:
  `DBOrderPage.fillScript` fills the form, `fetchScript` fetches order + PDFs inside the page; shown only when bahn.de
  asks for more, e.g. a captcha), `TicketView` (full-brightness barcode, PDF, `AddToWalletButton`, "Zugbindung
  aufgehoben"), `TicketButton` (in `JourneyDetailView` once the journey has tickets), `AddTicketButton`,
  `TicketsListView` (Settings → Gespeicherte Tickets; "Zeitkarten" like the Deutschland-Ticket from a screenshot via
  `PhotosPicker`, `TravelPassView`), `SeatReservationViews` (`ReservationRow` in `LegCard`;
  `AppModel.reservations(for:)`, only on the leg whose train matches; `SaveSeatButton`/`SaveSeatSheet`, #410).
- `Features/Trips/TripsView.swift` – upcoming/past journeys, `SaveJourneyButton` (warns "Zug ist
  reservierungspflichtig", in bike mode also "Fahrradreservierung nötig" / "Keine Fahrradmitnahme", via
  `AppModel.saveWarnings`; ticket/reservation imports never warn).
- Bike mode (#398): Settings → Fahrrad (`AppSettings.bikeOption`: Ausblenden (default), Klapprad, Fahrrad; synced). Unless
  hidden, the search options get "Mit Klapprad"/"Mit Fahrrad" (`AppSettings.searchWithBike`, carried as
  `ConnectionSearch.withBike`; results aren't filtered); `AppSettings.bike(searchingWithBike:)` gives the bike in effect.
  `JourneyDetailView` sets the environment value `bikeMode`: `LegCard` shows `BikeTransportRow`
  (`Features/Connections/BikeTransportViews.swift`, `AppModel.bikeTransport(for:bike:)`: title, ticket, note); for a normal
  bike the Wagenreihung frames the coaches with bike spaces in green and tints their sectors (Kit `CoachSequence.bikeCoaches`,
  `bikeSectors`, `bikeCoachSummary`). Kit `BikeTransport` (`Transit/BikeTransport.swift`): a folding bike rides as luggage
  everywhere (`.luggage`); a normal bike: DB's notices 91/92, no bike spaces (`hasBikeSpaces`: ICE 1/2/3/Velaro by series,
  an ICE whose bahn.de Wagenreihung has none, e.g. ICE T BR 415), bahn.de's bike attributes (`BahnDeClient.bikeTransport(for:)`:
  "FR" reservierungspflichtig, "FB" begrenzt, others by wording; narrowed to the leg's section), else the rules: long-distance
  trains with the Fahrradkarte Fernverkehr and a reservation, regional trains and S-Bahns per `BikeTariff`
  (`Transit/BikeTariffs.swift`, researched 2026-10-19: the Verbund both ends lie in, found by district via
  `StationNames.district(of:)` (AGS code in the DHID), else the state's rule, else DB's Fahrradtageskarte Nahverkehr; tickets
  that only apply Mo–Fr at some hours and S-Bahn Sperrzeiten (HVV, VGN) by the leg's departure, holidays not known).
  Transitous' `bikesAllowed` is no use: DELFI sends `false` for every German train.
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
- `Features/Sharing/` – shared-journey and DB-share previews; `JourneyShareButton` (menu: "Reise teilen" short link,
  falls back to the long one, `UIActivityViewController`; "Ankunft teilen" #317 adds an `ArrivalShare`, until 2 h after the arrival).
- `Features/Settings/` – settings (privacy link, "not affiliated with DB"), `DataSourcesView` (every source with its
  attribution/license; keep current when adding one), `BC100RulesView`, quick tags.
- `Shared/DesignSystem.swift` – `Card`, `SectionHeader`, `LineBadge`, `TimeStack`, `DelayPill`, `PlatformBadge`,
  `InfoChip`, `OperatorLabel`, `Color.brand`, `.transition(.fold)` …; reuse these instead of new styling.
- `Shared/ClosesMenusOnScroll.swift` – `.closesMenusOnScroll()` on scroll views with a `Menu` or menu `Picker` in their
  content (journey details, Settings, check-in): an open menu otherwise slides along while the content scrolls.
  `.resetsWhenMenusCloseOnScroll()` rebuilds a glass menu button (`JourneyShareButton`) that stayed where its menu was.
- `Shared/StationPicker.swift` (`StationInput`, `TimeSelector`), `LocationService`, `PreviewData`, `VagonwebBrowser`.
  `Shared/DebugScreens.swift` (DEBUG): `-debugScreen <name>`, `-seedDemoTrips YES`, `-seedStressTrips <count>`, `-seedSeatMapTrips YES` (two made-up ICEs leaving in 20 min with a reservation and a made-up Wagenreihung, `CoachSequence.seatMapDemo`: ICE 1 turned round, Wagen 12 Platz 43; ICE 3neo Wagen 24 Platz 78), `-seedCoachAdviceTrips YES` (coach advice, #383: ICE 9911 → Hannover Hbf Gleis 12 with ICE 9912 6 min later on Gleis 11, again as ICE 9921/9922 with a seat in the front coach; ICE 9913 ending at Frankfurt(Main)Hbf Gleis 13, leaving a minute after seeding and 20 min long; ICE 9931/9932 like 9911/9912 but left 10 min ago, for saving a seat, #410).

## BetterBahnKit (`Packages/BetterBahnKit/Sources/BetterBahnKit/`)

### Models

- `Journey` → `Leg` → `Stopover`, `Line`, `Product`, `TimeInfo` (planned/actual), `PlatformInfo`, `Trip`,
  `JourneyPage`, `Station` (+ `DataSource`, `Coordinate`), `BoardEntry`, `TrainMessage` (DB delay reasons/notices),
  `RideMatch`, `YearReview` (km, hours, punctuality < 6 min, series, stations, routes, countries from EVA/IFOPT, CO₂),
  `CO2Comparison` (#386: km × Umweltbundesamt g/Pkm per product, reference year 2024; car and domestic flight over the
  same km; walks, ferries and unknown products left out).
- `TravelCollection` (#384) – collected special liveries (`TrainsetLiveries`, per Tz), series (`TravelCollection.series`,
  unit model via `seriesName(of:)`: "ICE 3neo Redesign" → "ICE 3neo"), named trainsets (`TrainsetNames`) and
  `BigStations` (DB price class 1 and 2, shown as "Großer"/"Mittlerer Bahnhof", by DHID via `StationNames.dhid(for:)`; boarding, alighting, changing; arriving
  and leaving within 3 h is one visit). Only arrived, not cancelled legs; IC 1 coach sets don't count.
- `StationNames` (#205) – `Station.displayName`: DB's name for German stations, the national railway's with accents
  abroad, from `Resources/StationNames.json` (OpenStation with DHID/EVA, names from DB RIS via bahn.expert's
  `stopPlace/byTerm`). Matched by the DHID in the stop ID ("de:08135:0620" = "de:08135:620"), EVA, `aliases` (non-German
  feeds' train stops within 300 m, matched within 150 m; German feeds get none, those can be trams), same name within
  600 m (`nameWords`: "…bahnhof"/"…bf" stem), brackets-only difference within 300 m unless they name a mode or border
  point, a part of it within 150 m; abroad `StationNames.folded` within 3 km. Only the shown name changes: `id`/`name`
  stay the feed's. Headsigns: `MPlace.displayName(ofHeadsign:)`, else `StationNames.displayName(forName:)`.
  `Station.displayName(for:)` shortens "hlavní nádraží"/"hlavná stanica". `StationNames.preload()` at launch.
  `StationNames.evaNumber(for:)` (stations with a single EVA only) is used by `BahnDeClient.evaNumber(for:)` before
  bahn.de's search, so statistics, Timetables and Wagenreihung don't ask bahn.de per stop. Timetables also takes
  `mainEvaNumber(for:)` of a station with several levels (Leipzig Hbf, Berlin Südkreuz, #411).
- `OperatorBrand` (#166) – feed agency → EVU logo (`Assets.xcassets/Operators/Operator-<brand>`, `OperatorLabel`,
  light plate in dark mode if `needsPlateInDarkMode`; named DB S-Bahns show the "S", other "DB Regio AG …" the DB Regio
  logo), `OperatorBrand.displayName` ("ODEG", "Transdev"). International trains: `BahnDeClient.trainOperators(for:)`
  → `[TrainOperator]` from each stop's `adminID` (UIC code), shown by `TrainOperatorsLabel` (`OperatorLogo`) and at
  handover stops (`operatorStops(for:)`); the feed only names one.
- `TransitLogo` (#350) – product + feed agency → S-Bahn/U-Bahn logo (`Assets.xcassets/TransitLogos/Logo-<case>`, vector
  PDFs from Wikimedia Commons). Replaces the whole train tile (`IconTile(logo:)`, `LiveTrainIconTile`): DB's "S" for
  German S-Bahns (ÖBB/Salzburg: Austrian "S", SBB/DSB/… none), city "U" logos (Berlin, Hamburg, München, Nürnberg,
  Frankfurt, Wien, Stadtbahn Stuttgart), else the plain "U". Badges keep the SF symbols `s.circle.fill`/`u.square.fill`.
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
- `Transit/ExitSides.swift` (#394) – which side of the train the platform is on where the user gets off, from `Resources/ExitSides.json` (built by `scripts/make-exit-sides.py` from OpenStreetMap: per station and track the side for a compass `heading`, `terminal` for a dead-end track) merged with the hand-made `Resources/ExitSideOverrides.json` (same format, its tracks win, `merging`). `side(leaving: Leg)` / `side(leaving: Trip, at:)`: the station by EVA, Ril100 code or name within 1.5 km (`candidates`), the track by number (`normalizedTrack`: "7 D-G" → "7"), the train's direction from the route geometry's last 250 m, else the bearing from the previous stop (`arrivalHeading`); within 60° of the track's heading the stored side, the other way round the opposite, else nothing. Trains only (`Product.isTrain`: "2 (U5)" at Berlin Hbf is the U-Bahn's), entries of an S-Bahn/Stadtbahn station node (`light`) for S-Bahn trains only. Shown only at the user's own exit: `ExitSideArrow` under the platform badge of the arrival in `LegCard` and of the exit in `TripContent` (an arrow; tapping it says "Ausstieg in Fahrtrichtung links" in a popover), and in the exit reminder. Nothing leaves the device.
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
  info dot, `PlannedPlatformNote`. Applied in `CombinedProvider.journeys`, `CombinedProvider.trip(for:)` and, last
  of all, in `LiveRun`.
- `Transit/Transitous/TwinTrainStops.swift` – stops/platforms a long-distance train's own feed leaves out (ÖBB's RJ
  177; `mayLackStops`): taken from the same train in another feed on the leg's start board (`insertingMissingStops`,
  cached 12 h), shared stops take DB's names. Runs before the Czech platforms; journey view does both first
  (`completingStopsAndPlatforms`), then the live refresh. First step of `LiveRun` (`fillingMissingStops(in: trip)`).
- `Transit/Transitous/TripContinuation.swift` – a DB trip (DELFI) ending at a foreign stop (`mayEndAtBorder`; ICE 171
  Hamburg-Altona → Děčín) gets the trip carrying on there under the same number (the Czech "RJ 171", found on the
  departures within 10 min) joined to it (`joining`): one border stop, the continuation's name when it is a long-distance
  brand ("RJ 171", the first as `alternateName`). `CombinedProvider.completing(_:)` does it (3 s deadline) and fills a
  trip's Czech stops: CZPTT's planned platforms (`fillingCzechPlatforms`) and bahn.expert's live times
  (`fillingCzechLiveTimes`; Transitous has none there). `trip(id:source:)` completes; `TripView` and `LegTripSheet` load
  `plainTrip(id:source:)`, and `LiveRun` completes it after the first paint, since it takes a few requests the
  first time. Journeys do the same with legs (`mergeThroughTrainLegs`). A Träwelling check-in on such a run is still two
  statuses (`segments(for:)`). `TrainNumberSearch.named(after:)` gives a run found by number DB's name from the search result.
- `Transit/BahnDe/` – bahn.de web API only via `Server/bahnde-proxy` (`BahnDeProxy`, #342; URLs built on the Worker's
  `baseURL` and mapped onto it; endpoints as Travel::Status::DE::DBRIS): station-search fallback, `TrainModel`,
  `TrainsetNames`, `CoachSequence` (coaches, classes, amenities, sectors, direction; RE/RB via `sequenceReference`),
  Zusatzhalte (`inserting`, `nextRegularStop`), `fillingMissingPlatforms` (e.g. Hamburg Hbf), `correctingTrainNames`
  ("RJ 171" Transitous calls "ICE 171"). Live times (`ezZeit`; `correctingFromBoard`, `applyingLiveTimes`,
  `applyingLiveTimes(from:to:)`) beat DELFI's forecasts, but not a delay/early time DB Timetables set (`keepingDelays`),
  and never turn 2+ min early into on time (`turnsEarlyIntoOnTime`). The journey details (`journeyCourse`) are asked
  only by `LiveRun`, for legs and trip views alike: for a run underway or leaving within 12 h (`isRunningSoon`,
  `journeyStopsMaxAge`), hourly for one up to a week ahead that lacks a platform (`needsPlatforms`), platforms only for
  other railways' night trains (`takesOnlyPlatforms`). Responses cached; journey IDs (one departure
  board each) kept on the device for 12 h, a run bahn.de doesn't list remembered for 10 min (`JourneyIdStore`, #411).
  A hiccup (`isHiccup`: 5xx but the server's own 503 "paused", a dropped connection) is tried up to 3 times
  (`BahnDeProxy.attempts`). On failure the server is left alone (`BahnDeProxy.gate`: 10 min after 403/429/452, 2 min
  when down; a shorter pause never cuts a longer one short) and requests throw `rateLimited`, shown as
  "Plan-Wagenreihung · Aktuelle nicht verfügbar" / "Aktuelle Wagenreihung nicht verfügbar"; `CoachSequenceDisclosure`
  asks again once the pause is over (`pausedUntil()`). No other way to bahn.de:
  the Worker and the phone's hidden browser were refused. `requiresReservation(for:)` (attribute `RP`, also other
  railways via `lookupReference`; shares the `journeyCourse` cache) and `bikeTransport(for:)` (bike attributes, same cache).
- `Transit/BahnDe/Occupancy.swift` – DB's occupancy forecast (#399): the journey details' `auslastungsmeldungen` per stop
  (`JourneyStop.occupancy`, per `TravelClass`; a stop's level is for the train leaving it, level 0 = none) →
  `OccupancyForecast` (highest level from boarding up to the exit). Levels and texts as bahn.de's own `auslastungstexte`:
  1 gering, 2 mittel, 3 hoch, 4/99 außergewöhnlich hoch (`OccupancyLevel`). `occupancy(for: leg)` / `(for: trip, boarding:exit:)`
  share the `journeyCourse` cache (30 min old is fine); `cachedOccupancy(for:)` never asks bahn.de (search results).
  Shown for the class in Settings → Reiseklasse (`AppSettings.travelClass`, default 2nd, synced): `OccupancyButton`
  (icon, tap → words) by the train name in `LegCard` and `TripContent`, `OccupancyDetails` in `LegCard` "Mehr",
  `OccupancyIcon` in `JourneyCard`. DEBUG builds log the raw field per stop (category `occupancy`).
- `Transit/BahnDe/SeatMap.swift` – DB's seat map per ICE coach (#365, `Resources/SeatMaps.json`): coach numbers, type,
  each seat number's box as fractions of the drawing (lower coach numbers on the left on every sheet).
  `CoachSequence.Group.seatMapSheet` per trainset from its UIC numbers (`TrainModel.detectSubtype`) and coach count
  (`SeatMap.sheet`: ICE 1 with 12 or, modernised, 9 middle coaches; ICE 4 with 7, 12 or 13; all BR 403 on the Redesign
  sheet); `CoachSequence.seatMap(for:)` by coach number. Misprints on DB's sheets are fixed in the
  script's `CORRECTIONS` (408 Wagen 24: 76–78 printed as 75–77; 401.LDV Wagen 6: 42 printed as 43).
- `Transit/BahnDe/CoachAdvice.swift`, `StationPlatforms.swift` – where to board (#383). `StationPlatforms.at(eva:)` from
  `Resources/Platforms.json` (`scripts/make-platforms.py`): tracks sharing a platform, per track the OSM platform
  edge (ends, length), stairs/lifts/terminus exit and sector signs in metres along it. `CoachAdvice.plan(for:…)` per
  journey (tight transfers up to 15 min, longer ones to another platform only the stairs, the exit at the end; with a seat reservation on the arriving train the
  coaches to walk to before arriving, `walkBeforeArrival`, when that saves 30 m, else `alreadyThere` („Du sitzt schon im
  richtigen Wagen, …", only when another coach would be wrong), for the exit only at a terminus; where the journey ends at
  a terminus only its exit counts (`toExit`, `Track.ways(out:)`: the front of the train, not the underpasses along the
  platform): from a seat walking there through any class (`otherClass`, „In Wagen 21 (2. Klasse) wechseln"), without
  one, where your class stops 60 m short of it, its nearest coach („… möglichst nah am Ausgang", `nearestOfClass`)
  and from `approachTime` (15 min) before arriving the front in any class (`pickOut`); the connecting
  train's reservation is the target; class from a seat's coach, else the ticket, else Settings → Reiseklasse,
  `TravelClass.number`; a seat saved on the train, `AppModel.savedSeats`, counts like a reservation; said only when some
  coach of the train stands 60 m worse than the best of your class, so also when all of your class fit): the arriving train's Wagenreihung at the transfer
  station (its departure there, from its run) against the connecting train's at the same platform
  (`transfer(arriving:…)`, positions of the other track by shared sector names), else the stairs
  (`exit(sequence:…)`: OSM positions onto bahn.de's by the sector signs, else by the way the train runs, at a terminus it
  goes on from, reversing, away from the buffer stops, Stralsund Hbf); a
  connecting train without a Wagenreihung (S-Bahn, bus) still counts by its platform. Tracks match by section
  ("3a/b" → "3a" → "3", `StationPlatforms.trackKeys`). A train
  ending at a terminus has no Wagenreihung there: laid out from the buffer stops in its order at the stop before
  (`transfer(endingAt:…)`, `exit(endingAt:…)`). `CoachSequence.eva` is the EVA number it was asked for. At most
  two coaches per place and two places (`groups`, stairs at both of Köln Hbf's underpasses): „In Wagen 22–23 oder
  31–32 einsteigen, um … auszusteigen", on the train „In Wagen … wechseln", with a seat „Vor der Ankunft in …". From a
  seat, or on the train without one from the middle coach of the class (`aboard`, `middle(of:)`), only the nearest place.
- `Transit/BahnDe/SavedSeat.swift` – a seat saved without a reservation (#410): by ride (train, first stop, planned
  departure; the feed's trip ID can change), `trainName` as reservations name it ("RE 3307" for a regional line's
  run), `offered(on:)` from 15 min before the departure until the arrival, `saving(_:for:in:)` keeps one per ride
  and drops those 6 h past their arrival. `AppModel.savedSeats` (`savedSeats.json`, this device only).
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
  reads vagonweb's HTML and a browser's serialized DOM. Coach notes like "runs on ⑥, ⑦ until 13.6. and from 17.10., on 24., 25.12. …"
  are read when the whole note fits (`DayRestriction`), and `VagonwebComposition.operating(on:)` drops the coach on other
  days (a stop before 4:00 counts for the day before); any other wording is no restriction. Those trains' legs get
  only platforms from bahn.de (`BahnDeClient.takesOnlyPlatforms`).
- `Transit/BahnExpert/` – train type fallback (`TrainTypeLookup`, `DB-plan`) when bahn.de and vagonweb have none;
  bahn.de is only asked within `BahnDeClient.formationLookahead` (24 h). Needs `Referer` + non-curl UA (else empty
  206). Platforms bahn.de and Transitous lack (`ExpertPlatforms.swift`, `BahnExpertClient.fillingMissingPlatforms`):
  SBB/ÖBB stations of their EC/RJ(X), Nightjet, Euronight, InterRegio, on legs and trips (step 4 of `LiveRun`),
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
  `JourneyRefresher.droppingInferredOnTime` cleans older saves. `realtime(for:)` gives a leg's ends
  (`JourneyRefresher.refreshEnds`); a run's stops get `liveTrip` (`tripWithRealtime` + `fillMissingPlatforms`) through
  `LiveRun`, legs and trip views alike.

### Logic

- `Transit/LiveRun.swift` – the one way a train run gets its live data, for a saved journey's leg
  (`JourneyRefresher.refresh`, the part between origin and destination as a `Trip` via `run(of:)`/`applying(_:to:)`,
  `syncingEnds`) and the trip views (`AppModel.liveRun`, the whole run) alike, so the journey card and the run opened
  from it agree (before, ICE 279 showed +3/+18 on the card and "0" at every stop of the run). Fixed order: Transitous'
  twin stops, DB Timetables (`liveTrip`, within `knowsChanges`), `CombinedProvider.completing` (whole runs only),
  bahn.de's `journeyCourse` (Zusatzhalte, `applyingLiveTimes(keepingDelays:referee:)`, platforms, sleeping cars; the
  12-h/one-week rules above), bahn.expert platforms, Czech platforms. A `baseline` (the remembered trip,
  `AppModel.liveTrips`; the saved leg, `Leg.savedTrip`) fills what the fresh answers lack (`keepingKnown`: live time,
  platform, Zusatzhalt, night-train mark), matched by station and planned time (`isSameVisit`: another lap takes
  nothing), never overriding fresh data; its inferred "on time" is dropped hours ahead. `progress` paints the screen as
  the sources answer (the timetable after `LoadingDeadline.liveData` if DB is slow, bahn.de before and after the
  referee), each version with the baseline.
- `JourneyReplanner` (`continuations`, `fastestFirst`), `ConnectionCheck` (`ConnectionIssue`, `JourneyRefresher`: `refreshEnds`
  for every result on screen, `refresh` through `LiveRun`), `ExitReminder`, `PlatformChange` (push,
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
  fallback; `arrivalURL`), `ArrivalShare` (#317: last train from boarding to exit, bahn.de journey ID via
  `BahnDeClient.journeyId(for:)`, EVA numbers), `DBShare` + `DBShareImporter` (DB Navigator/bahn.de shared text).
- `Widgets/` – `WidgetSnapshot` + `WidgetStore` (App Group JSON), `JourneyWidgetState` (phase, next stop and delay,
  transfer, countdown; `changeDates`), `WidgetTimer` (> 12 h reads "2d 3h 49m"), `TrainMapLink` (`betterbahn://map`),
  `WidgetStations` (favourites + recent routes for the board widget's picker), `BoardWidgetLink` (`betterbahn://board`,
  the stations travel in the link as base64url JSON, also the widget entities' IDs), `BoardWidgetRows` (board widget
  rows from a board or from journeys, which are still ahead at a time with a 60 s grace, `changeDates`).
- `Calendar/JourneyCalendarEvent.swift` (#382) – title ("ICE 597 → München", with changes "Köln → München"; "Hbf" dropped only from 100 km straight-line distance, else "Bonn Hbf"),
  times, departure station with coordinate, notes (platforms, each change with transfer minutes, reserved
  seats, link) from a journey's latest data; `CalendarAccessMode`, `CalendarAutoAdd.isDue`. Not in `scripts/searchsim` (needs `Tickets/`).
- `Geometry/` – polyline decode, `RouteGeometryService`, `SegmentHeatmap`.
- `Weather/WeatherForecast.swift` (#385) – `WeatherClient` asks Open-Meteo's `/v1/forecast` (no key, CC BY 4.0) for a
  station's hourly forecast (temperature, rain chance/amount, wind, WMO code → `WeatherCondition`: German name + SF
  Symbol); only the station's position, rounded to 2 decimals, goes out. Kept per place for an hour, so reopening a
  journey asks nothing. `covers`: arrivals still ahead, up to 10 days. `Journey.weatherPoints`: the destination plus
  transfers with more than `weatherTransferWait` (15 min) to the next train, by live times; `weather(for:)` →
  `JourneyWeather`.

### Statistics, support

- `Statistics/TrainStatistics.swift` (#316) – `TrainStatistics` (30 days per stop: delays, cancellations, platform
  moves), `TrainStatisticsClient`, `TrainStatisticsStore` (cache per train and day; off with
  `AppSettings.showTrainStatistics`; EVA via `BahnDeClient.evaNumber(for:)`). Shown from `minimumRuns` (5); launch arg
  `-debugstats` enables `TrainStatistics.testMode` for that launch only (`enableTestModeIfRequested`: from 1 run,
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
  jump from timetable to delays (`LiveRun` for runs). `Support/LiveDataCache.swift` – `AppModel.liveJourneys`/`liveTrips`
  (12 h, 50 each) show at once and refresh in the background, as the baseline of `LiveRun` for a trip; `AppModel.prepareLiveData`
  for the first search result.
- `Support/WorkerAuth.swift` – App Attest for own Workers: attests once, hourly `X-BetterBahn-Token`,
  `HTTPClient.sendRaw(_:auth:)` retries once after a 401; only on the real `URLSession.shared` (mocked tests get none).

## Tests and conventions

- Kit tests use Swift Testing with HTTP mocked by a `URLProtocol` subclass + `Tests/.../Fixtures/*.json`. Use
  `swift-test.sh` (temp `--scratch-path`): plain `swift test` can fail codesigning on `.build` attributes.
- Content folding in or out uses `.transition(.fold)`, never `.move(edge: .top)` (slides over the text above).
- DB-style station names ("Frankfurt (Oder)", "Bernau (bei Berlin)").
- Commit titles: short imperative sentence ("Show …", "Stop …", "Keep …").
