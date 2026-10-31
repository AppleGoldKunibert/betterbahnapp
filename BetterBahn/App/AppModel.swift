import BackgroundTasks
import BetterBahnKit
import EventKit
import Foundation
import Network
import Observation
import os
import UserNotifications

@Observable
final class AppModel {
    let settings = AppSettings()
    private(set) var provider: CombinedProvider
    private(set) var traewelling: TraewellingClient
    let liveActivities = LiveActivityManager()
    @ObservationIgnored let customEmojis = CustomEmojiClient()

    var favoriteStations: [Station] {
        didSet {
            Storage.save(favoriteStations, key: "favoriteStations")
            favoriteStationsCloud.localChange(from: oldValue, to: favoriteStations)
            updateWidgetStations()
            scheduleSpotlightSync()
        }
    }
    var recentSearches: [RecentSearch] {
        didSet {
            Storage.save(recentSearches, key: "recentSearches")
            recentSearchesCloud.localChange(from: oldValue, to: recentSearches)
            updateWidgetStations()
        }
    }
    /// A station whose board the Abfahrten tab shows next: set when the departure board widget is tapped
    /// (`BoardWidgetLink`), cleared by `StationBoardView` once shown.
    var boardStationToOpen: Station?
    /// A search the Verbindungen tab runs next: the widget's commuter route, cleared by `ConnectionsView`.
    var searchToOpen: ConnectionSearch?
    /// Journeys the user saved. The next upcoming one is shown as Live Activity.
    var savedJourneys: [SavedJourney] {
        didSet {
            // Every saved journey with all its stops is encoded here, which takes noticeably long
            // once there are many, so it happens off the main thread.
            Storage.saveInBackground(savedJourneys, key: "savedJourneys")
            journeyCloud.localChange(from: oldValue, to: savedJourneys)
            syncLiveActivity()
            scheduleExitReminderSync()
            scheduleCalendarSync()
            scheduleSpotlightSync()
            commuteJourneysChanged(from: oldValue)
        }
    }
    /// Journeys the user takes on the same weekdays (#397): on each of those days the app asks shortly before
    /// the departure whether they ride today, and a yes saves that day's journey (see `CommuteModel.swift`).
    var regularTrips: [RegularTrip] {
        didSet {
            Storage.save(regularTrips, key: "regularTrips")
            regularTripsCloud.localChange(from: oldValue, to: regularTrips)
            if regularTrips != oldValue { scheduleCommuteQuestions() }
        }
    }
    /// "Fährst du heute?" to ask in the app, after its notification was tapped.
    var commuteQuestionToAsk: CommuteQuestion?
    /// This device at the push Worker for regular trips, made on the first sign-up.
    @ObservationIgnored var commutePushRegistration: CommutePushRegistration? = Storage.load(key: "commutePushRegistration") {
        didSet { Storage.save(commutePushRegistration, key: "commutePushRegistration") }
    }
    /// The saved journeys (by `SavedJourney.id`) the Worker reports problems of; the app leaves those to it.
    @ObservationIgnored var commutePushWatched: Set<String> = Storage.load(key: "commutePushWatched") ?? [] {
        didSet { Storage.save(commutePushWatched, key: "commutePushWatched") }
    }
    /// What the Worker was last sent, so an unchanged list isn't sent again on every start.
    @ObservationIgnored var commutePushSent: Data? = Storage.load(key: "commutePushSent") {
        didSet { Storage.save(commutePushSent, key: "commutePushSent") }
    }
    @ObservationIgnored var commuteQuestionsTask: Task<Void, Never>?
    @ObservationIgnored var commutePushTask: Task<Void, Never>?
    /// Tickets fetched from bahn.de, kept on this device only (see `TicketStore`).
    var tickets: [SavedTicket] {
        didSet { TicketStore.save(tickets) }
    }
    /// Passes such as the Deutschland-Ticket, kept on this device only like `tickets`.
    var travelPasses: [TravelPass] {
        didSet { TicketStore.savePasses(travelPasses) }
    }
    /// Live versions of journeys and train runs already loaded once (see `LiveDataCache`), kept on disk
    /// so after a restart too they show at once while a background refresh runs instead of a spinner.
    @ObservationIgnored private(set) var liveJourneys = LiveDataCache<Journey>()
    @ObservationIgnored private(set) var liveTrips = LiveDataCache<Trip>()
    /// Laps of looping trains (Ringbahn) loaded by "Vorherige / Nächste Runde laden", kept on disk; unsaved
    /// trips forget them after 15 minutes without a look (see `LoadedLaps`).
    @ObservationIgnored private var loadedLaps = LoadedLaps()
    /// What DB decided for transfers at the last refreshes (by the departing leg's `id`), for the exit reminders.
    @ObservationIgnored var transferDispositions: [String: TransferDisposition] = [:]
    @ObservationIgnored var exitReminderSync: Task<Void, Never>?
    @ObservationIgnored var exitReminderGeneration = 0
    /// Calendar events of saved journeys on this device (#382), see `CalendarEvents.swift`.
    var calendarEventIDs: [UUID: String] = CalendarEventLog.load() {
        didSet { CalendarEventLog.save(calendarEventIDs) }
    }
    @ObservationIgnored var calendarStore: EKEventStore?
    /// Counts the times calendar access was granted, so the calendar setting reloads its list.
    var calendarAccessChanges = 0
    @ObservationIgnored var calendarSync: Task<Void, Never>?
    /// Saved journey to open on the Verbindungen tab (set when the Live Activity is tapped);
    /// `ConnectionsView` pushes it and clears this.
    var journeyToOpen: SavedJourney?
    /// Shows the train search (`TrainSearchOverlay`) over every tab.
    var showsTrainSearch = false
    /// A deep link to open, set when a station or journey is opened from Spotlight (#387);
    /// `RootView` opens it and clears this.
    var linkToOpen: URL?
    /// The waiting Spotlight update and what Spotlight was last given (see `SpotlightSync`).
    @ObservationIgnored var spotlightSync: Task<Void, Never>?
    @ObservationIgnored var lastSpotlightEntries: [SpotlightEntry]?
    /// Recently picked stations, newest first (used as suggestions).
    var recentStations: [Station] {
        didSet { Storage.save(recentStations, key: "recentStations") }
    }
    /// Manual Träwelling check-ins (trains Träwelling didn't know) whose delay we keep pushing
    /// until the trip arrives, since Träwelling has no timetable of its own to track that.
    var trackedManualCheckins: [TrackedManualCheckin] {
        didSet { Storage.save(trackedManualCheckins, key: "trackedManualCheckins") }
    }
    /// Träwelling status of each leg checked in from this app (by `Leg.id`), so the leg's "Mehr"
    /// offers "Check-in ansehen" instead of checking in again.
    var checkinStatusIDs: [String: Int] {
        didSet { Storage.save(checkinStatusIDs, key: "checkinStatusIDs") }
    }
    /// Seats saved on the trains being ridden, without a reservation (#410); forgotten a while after the ride.
    private(set) var savedSeats: [SavedSeat] {
        didSet { Storage.save(savedSeats, key: "savedSeats") }
    }
    /// Explicit choice (from the route view) of which saved journey's Live Activity to show,
    /// overriding the automatic pick until that journey finishes or another one is chosen.
    /// Journeys whose Live Activity was switched off by hand, so the automatic pick skips them.
    var dismissedLiveActivityJourneyIDs: Set<UUID> = Set(
        (UserDefaults.standard.stringArray(forKey: "dismissedLiveActivityJourneyIDs") ?? []).compactMap(UUID.init)
    ) {
        didSet {
            UserDefaults.standard.set(dismissedLiveActivityJourneyIDs.map(\.uuidString), forKey: "dismissedLiveActivityJourneyIDs")
            syncLiveActivity()
        }
    }

    func setLiveActivity(_ on: Bool, for id: UUID) {
        if on {
            dismissedLiveActivityJourneyIDs.remove(id)
            manualLiveActivityJourneyID = id
        } else {
            if manualLiveActivityJourneyID == id { manualLiveActivityJourneyID = nil }
            dismissedLiveActivityJourneyIDs.insert(id)
        }
    }

    var manualLiveActivityJourneyID: UUID? {
        didSet {
            if let id = manualLiveActivityJourneyID {
                UserDefaults.standard.set(id.uuidString, forKey: "manualLiveActivityJourneyID")
            } else {
                UserDefaults.standard.removeObject(forKey: "manualLiveActivityJourneyID")
            }
            syncLiveActivity()
        }
    }

    init() {
        // The list of station names every stop is shown under, read before the first screen needs it.
        Task { await StationNames.preload() }
        provider = CombinedProvider(vagonweb: VagonwebClient(browserLoader: { url in try await VagonwebBrowser.shared.html(at: url) }))
        traewelling = TraewellingClient(config: TraewellingConfig(), keepAlive: { await BackgroundTime.begin(named: "Träwelling-Anmeldung") })
        // Older versions stored everything in UserDefaults; move the raw bytes into files once
        // (re-encoding everything on every launch is what used to slow the start down).
        Storage.migrateFromUserDefaults(keys: ["savedJourneys", "favoriteStations", "recentSearches", "recentStations"])
        favoriteStations = Storage.load(key: "favoriteStations") ?? []
        recentSearches = Storage.load(key: "recentSearches") ?? []
        recentStations = Storage.load(key: "recentStations") ?? []
        // Sorted again: journeys an earlier build took over from iCloud were stored unsorted.
        savedJourneys = (Storage.load(key: "savedJourneys") ?? []).sorted(by: SavedJourney.departsEarlier)
        regularTrips = Storage.load(key: "regularTrips") ?? []
        trackedManualCheckins = Storage.load(key: "trackedManualCheckins") ?? []
        checkinStatusIDs = Storage.load(key: "checkinStatusIDs") ?? [:]
        let seats: [SavedSeat] = Storage.load(key: "savedSeats") ?? []
        savedSeats = seats.filter { !$0.isOver() }
        liveJourneys = Storage.load(key: "liveJourneys") ?? LiveDataCache()
        liveTrips = Storage.load(key: "liveTrips") ?? LiveDataCache()
        loadedLaps = Storage.load(key: "loadedLaps") ?? LoadedLaps()
        tickets = TicketStore.load()
        travelPasses = TicketStore.loadPasses()
        manualLiveActivityJourneyID = UserDefaults.standard.string(forKey: "manualLiveActivityJourneyID").flatMap(UUID.init)
        updateWidgetStations()
        scheduleSpotlightSync()
        // The check-in history can run to thousands of trips, so it's decoded off the main thread
        // instead of blocking the launch.
        traewellingTripsLoadTask = Task { [weak self] in
            // Earlier versions kept every trip's track geometry in this file; it moves to the
            // geometry cache, which stores it far more compactly (#170).
            let (trips, geometries) = await Task.detached(priority: .userInitiated) { () -> ([ImportedTrip], [String: [Coordinate]]) in
                ImportedTrip.movingGeometryOut(of: Storage.load(key: "traewellingTrips") ?? [])
            }.value
            guard let self else { return }
            await rememberGeometries(geometries)
            traewellingTrips = trips
            traewellingTripsLoaded = true
            if !geometries.isEmpty { traewellingTrips = trips } // saves the slimmed-down list
        }
        // After init, since taking over synced journeys also updates the Live Activity.
        Task { [weak self] in self?.startCloudSync() }
    }

    @ObservationIgnored private var cloudObserver: NSObjectProtocol?
    @ObservationIgnored private let favoriteStationsCloud = CloudList<Station>(key: "favoriteStations")
    @ObservationIgnored private let recentSearchesCloud = CloudList<RecentSearch>(key: "recentSearches")
    /// Saved journeys sync through CloudKit instead (#427): as one key-value store value they outgrew its 1 MB.
    @ObservationIgnored private let journeyCloud = JourneyCloudSync()
    @ObservationIgnored private let regularTripsCloud = CloudList<RegularTrip>(key: "regularTrips")

    /// Merges with what iCloud already has (uploading what only exists here, e.g. on the first
    /// launch after updating) and takes over changes made on the user's other devices.
    private func startCloudSync() {
        applyCloudChange(keys: ["favoriteStations", "recentSearches", "regularTrips", AppSettings.cloudKey])
        journeyCloud.start(model: self)
        cloudObserver = CloudSync.observe { [weak self] keys in
            self?.applyCloudChange(keys: keys)
        }
    }

    private func applyCloudChange(keys: [String]) {
        if keys.contains("favoriteStations") {
            favoriteStationsCloud.receive(local: favoriteStations) { favoriteStations = $0 }
        }
        if keys.contains("recentSearches") {
            recentSearchesCloud.receive(local: recentSearches) { recentSearches = $0 }
        }
        if keys.contains("regularTrips") {
            regularTripsCloud.receive(local: regularTrips) { regularTrips = $0 }
        }
        if keys.contains(AppSettings.cloudKey) { settings.receiveCloudValue() }
    }

    /// Takes over journeys changed on the other devices (when the app comes to the foreground).
    func fetchCloudJourneys() {
        journeyCloud.fetch()
    }

    var trainPicker: TrainPicker { TrainPicker(provider: provider) }

    var journeyReplanner: JourneyReplanner { JourneyReplanner(provider: provider, timetables: timetablesClient) }

    var dbShareImporter: DBShareImporter { DBShareImporter(provider: provider, bahnDe: provider.bahnDe ?? BahnDeClient()) }

    var trainRoutePlanner: TrainRoutePlanner { TrainRoutePlanner(provider: provider, timetables: timetablesClient) }

    /// Rules for the "only valid with my ticket" filters, for the ticket picked in the settings.
    var ticketFilter: TicketFilter {
        switch settings.ticketType {
        case .deutschlandticket: .deutschlandticket
        case .bahnCard100: .bahnCard100(settings.bc100Rules)
        }
    }

    /// Overlays fresher delay/platform data straight from DB onto legs, through BetterBahn's proxy
    /// (which holds the API key). `nil` where the app can't prove it's genuine (no App Attest, e.g.
    /// in the Simulator), since the proxy refuses those requests.
    var timetablesClient: TimetablesClient? {
        guard WorkerAuth.shared.isSupported else { return nil }
        return TimetablesClient()
    }

    var journeyRefresher: JourneyRefresher { JourneyRefresher(provider: provider, timetables: timetablesClient) }
    /// Loads a train run's live data for the trip views, the same way `journeyRefresher` does for a leg.
    var liveRun: LiveRun { LiveRun(provider: provider, timetables: timetablesClient) }

    /// Whether `journey` was already loaded with live data: saved (refreshed in the background, also
    /// right after launch) or opened or prepared before. Only an unseen one waits for live data.
    func hasLiveData(for journey: Journey) -> Bool {
        savedEntry(for: journey) != nil || liveJourneys.value(for: journey.id) != nil
    }

    func rememberLive(_ journey: Journey) {
        liveJourneys.store(journey, for: journey.id)
        let snapshot = liveJourneys
        Task.detached(priority: .utility) { Storage.save(snapshot, key: "liveJourneys") }
    }

    func rememberLive(_ trip: Trip) {
        liveTrips.store(trip, for: trip.id)
        let snapshot = liveTrips
        Task.detached(priority: .utility) { Storage.save(snapshot, key: "liveTrips") }
    }

    /// The laps to show when a looping train's trip is opened (`LoadedLaps.open`).
    func openLoadedLaps(_ key: String, tripId: String) -> LoadedLaps.Extra {
        let extra = loadedLaps.open(key, isSaved: isTripSaved(tripId))
        saveLoadedLaps()
        return extra
    }

    func rememberLoadedLaps(_ extra: LoadedLaps.Extra, for key: String, tripId: String) {
        loadedLaps.store(extra, for: key, tripId: tripId, isSaved: { isTripSaved($0) })
        saveLoadedLaps()
    }

    /// The trip was left: its laps stay another 15 minutes.
    func closeLoadedLaps(_ key: String) {
        loadedLaps.viewed(key)
        saveLoadedLaps()
    }

    private func saveLoadedLaps() {
        let snapshot = loadedLaps
        Task.detached(priority: .utility) { Storage.save(snapshot, key: "loadedLaps") }
    }

    /// Loads the live data of a search result before it's opened (the first one), so its plan shows
    /// without waiting.
    func prepareLiveData(for journey: Journey) {
        guard !hasLiveData(for: journey) else { return }
        let refresher = journeyRefresher
        Task { [weak self] in
            let refreshed = await refresher.refresh(journey)
            self?.rememberLive(refreshed)
        }
    }

    /// Applies a manual realtime refresh (e.g. pull-to-refresh in the journey detail view) to a
    /// saved journey in place, without touching its version history or already-sent notifications.
    func updateSavedJourneyData(id: UUID, journey: Journey) {
        guard let index = savedJourneys.firstIndex(where: { $0.id == id }) else { return }
        savedJourneys[index].journey = journey
    }

    func toggleFavorite(_ station: Station) {
        if let index = favoriteStations.firstIndex(where: { $0.isSamePlace(as: station) }) {
            favoriteStations.remove(at: index)
        } else {
            favoriteStations.append(station)
        }
    }

    func isFavorite(_ station: Station) -> Bool {
        favoriteStations.contains { $0.isSamePlace(as: station) }
    }

    /// Clears recently searched stations and connections only. Favorites, saved journeys, imported
    /// Träwelling trips, and the Träwelling login itself (kept in the Keychain, not here) are untouched.
    func clearSearchHistory() {
        recentStations = []
        recentSearches = []
    }

    // MARK: Träwelling sync

    /// Check-ins of the people the user follows on Träwelling on a train or leaving soon (#196), kept fresh by
    /// `keepFollowedCheckinsFresh()` while the Verbindungen tab is shown.
    var followedCheckins: FollowedCheckins?
    @ObservationIgnored var followedCheckinsLoadedAt: Date?
    /// What opening a followed check-in looked up, by status ID, so opening it again shows it at once:
    /// Träwelling's track of the ride (empty: it has none) and the train found in the timetable. A train not
    /// found isn't remembered: it is looked for again whenever the check-in is opened.
    @ObservationIgnored var followedTracks: [Int: [Coordinate]] = [:]
    @ObservationIgnored var followedTrains: [Int: Leg] = [:]
    /// Train lookups under way, by status ID: they finish even when the card that asked is folded away.
    @ObservationIgnored var followedTrainLoads: [Int: Task<Leg?, Error>] = [:]
    /// The custom emojis for each followed check-in's text, loaded with the list so its pictures are ready on opening.
    @ObservationIgnored var followedEmojis: [Int: [CustomEmoji]] = [:]
    /// This device's sign-up at the push Worker for notifications about followed check-ins (#266) and the
    /// user's own (#447), nil while they're all off. Kept after turning them off until the Worker confirmed
    /// the sign-off.
    @ObservationIgnored var followedCheckinPush: FollowedCheckinPushSubscription? = Storage.load(key: "followedCheckinPush") {
        didSet { Storage.save(followedCheckinPush, key: "followedCheckinPush") }
    }
    /// The Worker dropped the sign-up (Träwelling ended its login); Settings says so.
    var followedCheckinPushEnded = false
    /// The APNs device token iOS gave this launch, the one and the kinds the Worker last got, and who waits for one.
    @ObservationIgnored var pushDeviceToken: String?
    @ObservationIgnored var followedCheckinPushSentToken: String?
    @ObservationIgnored var followedCheckinPushSentKinds: Set<CheckinPushKind>?
    @ObservationIgnored var pushDeviceTokenWaiters: [CheckedContinuation<String?, Never>] = []
    /// A followed check-in to show, from tapping its notification; the Verbindungen tab opens it once it's in the list.
    var followedCheckinToOpen: Int?
    /// The user's own check-in to show, from tapping a like's notification (#447); the journey opened with
    /// `journeyToOpen` shows it and clears this.
    var checkinToShow: Int?

    /// Check-ins imported from Träwelling (newest first), shown on the travel map. Empty until
    /// loaded from disk after launch; `loadTraewellingTrips()` waits for that.
    var traewellingTrips: [ImportedTrip] = [] {
        didSet {
            guard traewellingTripsLoaded else { return }
            // Encoded and written in the background (it's large); chained so saves land in order.
            let trips = traewellingTrips, previous = traewellingTripsSaveTask
            traewellingTripsSaveTask = Task.detached(priority: .utility) {
                await previous?.value
                Storage.save(trips, key: "traewellingTrips")
            }
        }
    }
    @ObservationIgnored private var traewellingTripsLoaded = false
    @ObservationIgnored private var traewellingTripsLoadTask: Task<Void, Never>?
    @ObservationIgnored private var traewellingTripsSaveTask: Task<Void, Never>?

    /// Waits until the check-in history has been read from disk.
    func loadTraewellingTrips() async {
        await traewellingTripsLoadTask?.value
    }
    private(set) var isSyncingTraewelling = false
    private(set) var traewellingSyncError: String?

    /// Fetches new check-ins and their track geometry, page by page (#170): the trips show up bit by bit,
    /// and an import that stopped half way continues where it was (`traewellingImportNextPage`)
    /// instead of starting over. Runs on even when the screen that started it goes away.
    func syncTraewelling(force: Bool = false) async {
        await Task { await self.runTraewellingSync(force: force) }.value
    }

    private func runTraewellingSync(force: Bool) async {
        // Without the stored history every check-in would look new and be imported again.
        await loadTraewellingTrips()
        guard settings.traewellingEnabled, settings.syncTraewellingToMap, !isSyncingTraewelling, await traewelling.isLoggedIn else { return }
        if !force, let last = settings.lastTraewellingSync, Date.now.timeIntervalSince(last) < 15 * 60 { return }
        isSyncingTraewelling = true
        defer { isSyncingTraewelling = false }
        var knownIDs = Set(traewellingTrips.map(\.statusID))
        // A first import has nothing to stop at: it walks the whole history, remembering how far it got.
        var resumePage = knownIDs.isEmpty ? (settings.traewellingImportNextPage ?? 1) : settings.traewellingImportNextPage
        // A full resync walks every page and compares each check-in with the ride imported for it: an
        // edit on Träwelling (e.g. checking out at another stop) keeps the status ID.
        let walkingAll = force && !knownIDs.isEmpty
        var refreshing: [Int: Journey] = walkingAll
            ? Dictionary(traewellingTrips.map { ($0.statusID, $0.journey) }, uniquingKeysWith: { first, _ in first })
            : [:]
        var seen: Set<Int> = []
        var pending: [ImportedTrip] = []
        // Hands the loaded trips to the map now and then (saving the whole list after every page would
        // rewrite a large file hundreds of times), and only then moves the resume point past them.
        func commit() {
            if !pending.isEmpty {
                let replaced = Set(pending.map(\.statusID))
                traewellingTrips = (pending + traewellingTrips.filter { !replaced.contains($0.statusID) })
                    .sorted { $0.statusID > $1.statusID }
                pending = []
            }
            settings.traewellingImportNextPage = resumePage
        }
        defer { commit() }
        do {
            let username = try await traewelling.currentUser().username
            // New check-ins first, down to the newest one imported before; then, if an earlier import
            // stopped half way, the older pages it didn't get to.
            var backfilling = knownIDs.isEmpty
            var page = backfilling ? resumePage ?? 1 : 1
            while true {
                let result = try await traewelling.historyPage(username: username, page: page, knownIDs: knownIDs,
                                                               refreshing: refreshing)
                seen.formUnion(result.statusIDs)
                let trips = result.trips.map { ImportedTrip(statusID: $0.statusID, journey: $0.journey) }
                let edited = Set(trips.map(\.statusID)).intersection(refreshing.keys)
                if !edited.isEmpty {
                    // An edited check-in keeps its leg ID, so its old track would be drawn from the cache.
                    await forgetGeometries(of: traewellingTrips.filter { edited.contains($0.statusID) }.flatMap(\.journey.legs))
                    // Paging by offset can repeat a status when a check-in lands mid-sync.
                    for id in edited { refreshing[id] = nil }
                }
                let (stripped, geometries) = ImportedTrip.movingGeometryOut(of: trips)
                await rememberGeometries(geometries)
                pending += stripped
                knownIDs.formUnion(result.trips.map(\.statusID))
                if !result.hasMore {
                    resumePage = nil
                    commit()
                    // A full resync that got through every page has seen every status there is. A check-in
                    // deleted on Träwelling (e.g. a cancelled ride) would otherwise stay in the local copy
                    // forever and keep counting on the map.
                    if walkingAll, !seen.isEmpty {
                        let deleted = traewellingTrips.filter { !seen.contains($0.statusID) }
                        if !deleted.isEmpty {
                            await forgetGeometries(of: deleted.flatMap(\.journey.legs))
                            traewellingTrips.removeAll { !seen.contains($0.statusID) }
                        }
                    }
                    break
                }
                if backfilling {
                    resumePage = page + 1
                    page += 1
                } else if walkingAll {
                    // Pages an earlier import didn't get to are imported on the way.
                    if let next = resumePage { resumePage = max(next, page + 1) }
                    page += 1
                } else if result.reachedKnown {
                    guard let next = resumePage else { break }
                    backfilling = true
                    // One page back, since check-ins deleted meanwhile move the rest forward.
                    page = max(next - 1, page + 1)
                } else {
                    page += 1
                }
                if pending.count >= 100 { commit() }
                // Two requests per page; Träwelling allows about 60 a minute (`historyPage` waits out a 429).
                try await Task.sleep(for: .seconds(1))
            }
            settings.lastTraewellingSync = .now
            traewellingSyncError = nil
        } catch {
            traewellingSyncError = error.localizedDescription
        }
    }

    // MARK: Track geometry

    @ObservationIgnored private let geometryService = RouteGeometryService()
    /// Leg ID → encoded polyline, persisted so the map doesn't reload everything. Träwelling's track
    /// geometry lives here too rather than in `traewellingTrips` (#170): as encoded polylines it takes
    /// a fraction of the space. Loaded off the main thread on first use, since the file can grow large.
    @ObservationIgnored private var geometryCache: [String: String]?
    @ObservationIgnored private var geometryCacheLoad: Task<[String: String], Never>?
    @ObservationIgnored private var geometryCacheSaveDelay: Task<Void, Never>?

    private func loadedGeometryCache() async -> [String: String] {
        if let geometryCache { return geometryCache }
        let task = geometryCacheLoad ?? Task.detached(priority: .utility) { () -> [String: String] in
            Storage.load(key: "legGeometries") ?? [:]
        }
        geometryCacheLoad = task
        let loaded = await task.value
        if geometryCache == nil { geometryCache = loaded }
        return geometryCache ?? loaded
    }

    /// Writes the cache a moment after the last change. Filling in thousands of legs used to rewrite
    /// the whole file, with its own copy of the cache in memory, once per leg, which with a long
    /// Träwelling history ran the app out of memory (#170).
    private func saveGeometryCache() {
        geometryCacheSaveDelay?.cancel()
        geometryCacheSaveDelay = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let cache = self?.geometryCache else { return }
            Storage.saveInBackground(cache, key: "legGeometries")
        }
    }

    func geometry(for leg: Leg) async -> [Coordinate]? {
        let cache = await loadedGeometryCache()
        if let encoded = cache[leg.id] {
            let cached = Polyline.decode(encoded)
            // Earlier versions cached straight lines between the two stations; look those up again
            // instead of drawing them across the map forever.
            if RouteGeometryService.followsTracks(cached) { return cached }
        }
        guard let geometry = await geometryService.geometry(for: leg) else { return nil }
        geometryCache?[leg.id] = Polyline.encode(geometry)
        saveGeometryCache()
        return geometry
    }

    /// Adds track geometry that came with the data (Träwelling sends it with each check-in).
    func rememberGeometries(_ geometries: [String: [Coordinate]]) async {
        guard !geometries.isEmpty else { return }
        let encoded = await Task.detached(priority: .utility) {
            geometries.mapValues { Polyline.encode($0) }
        }.value
        _ = await loadedGeometryCache()
        geometryCache?.merge(encoded) { _, new in new }
        saveGeometryCache()
    }

    private func forgetGeometries(of legs: [Leg]) async {
        guard !legs.isEmpty else { return }
        _ = await loadedGeometryCache()
        for leg in legs { geometryCache?[leg.id] = nil }
        saveGeometryCache()
    }

    /// The already-cached geometry of many legs at once, decoded off the main thread.
    ///
    /// The map needs a few hundred of these at a time; decoding them one by one from a main-actor
    /// loop is what used to freeze the screen for half a minute. Returns the legs it couldn't
    /// serve, which the caller then loads individually.
    func cachedGeometries(for legs: [Leg]) async -> (lines: [(leg: Leg, coordinates: [Coordinate])], missing: [Leg]) {
        let cache = await loadedGeometryCache()
        let encoded = legs.map { (leg: $0, encoded: cache[$0.id]) }
        return await Task.detached(priority: .userInitiated) {
            var lines: [(leg: Leg, coordinates: [Coordinate])] = []
            var missing: [Leg] = []
            for entry in encoded {
                guard let string = entry.encoded else { missing.append(entry.leg); continue }
                let coordinates = Polyline.decode(string)
                if RouteGeometryService.followsTracks(coordinates) {
                    lines.append((entry.leg, coordinates))
                } else {
                    missing.append(entry.leg)
                }
            }
            return (lines, missing)
        }.value
    }

    // MARK: Travel map heatmap

    /// The result of merging a set of journeys' track geometry into colored map segments.
    struct MapHeatmap: Codable, Equatable {
        var runs: [SegmentHeatmap.Run]
        var journeysCount: Int
        var legsCount: Int
        var kilometers: Double
        var hours: Double
    }

    /// Keyed by everything the heatmap depends on (date range, filters, data counts), so it
    /// survives reopening the map or relaunching the app until the underlying data changes.
    @ObservationIgnored private var mapHeatmapCacheTask: Task<[String: MapHeatmap], Never>?

    private func loadedMapHeatmapCache() async -> [String: MapHeatmap] {
        if let mapHeatmapCacheTask { return await mapHeatmapCacheTask.value }
        let task = Task.detached(priority: .utility) { () -> [String: MapHeatmap] in
            Storage.load(key: "mapHeatmapCache") ?? [:]
        }
        mapHeatmapCacheTask = task
        return await task.value
    }

    func cachedMapHeatmap(for key: String) async -> MapHeatmap? {
        await loadedMapHeatmapCache()[key]
    }

    func setCachedMapHeatmap(_ value: MapHeatmap, for key: String) async {
        var cache = await loadedMapHeatmapCache()
        // Keep only the most recent entries; each holds full route geometry, so unbounded growth
        // (e.g. from toggling filters/ranges a lot) would bloat the cache file.
        if cache.count >= 20, cache[key] == nil { cache.removeValue(forKey: cache.keys.randomElement()!) }
        cache[key] = value
        mapHeatmapCacheTask = Task { cache }
        Task.detached(priority: .utility) { Storage.save(cache, key: "mapHeatmapCache") }
    }

    // MARK: Travel map prewarm

    @ObservationIgnored private var mapPrewarmTask: Task<Void, Never>?

    /// Warms the travel map in the background after launch so opening its tab is instant.
    ///
    /// The slow part is the track geometry, which is fetched leg by leg and may hit the network, so
    /// this runs at low priority with a pause between ranges — a long history mustn't compete with
    /// what the user is actually doing. Results land in the same cache the map view reads.
    func prewarmTravelMap() {
        guard mapPrewarmTask == nil else { return }
        mapPrewarmTask = Task(priority: .utility) { [self] in
            // Let the app finish launching before touching the disk and the network.
            try? await Task.sleep(for: .seconds(3))
            // Träwelling check-ins are part of the map, and the cache key counts them — warming
            // before the sync lands would just cache a result that's stale right away.
            await syncTraewelling()
            // RootView kicks off a sync of its own on launch; `syncTraewelling` returns right away
            // while that one runs, so wait it out rather than caching a result the new check-ins
            // invalidate a moment later.
            while isSyncingTraewelling, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
            }
            for range in TravelMapRange.prewarmOrder {
                guard !Task.isCancelled else { break }
                _ = await mapHeatmap(for: TravelMapSelection(range: range), progressively: false)
                try? await Task.sleep(for: .seconds(1))
            }
            mapPrewarmTask = nil
        }
    }

    /// Stops the prewarm while the map view builds the same thing itself. Nothing is lost: the
    /// geometry fetched so far is already cached.
    func stopTravelMapPrewarm() {
        mapPrewarmTask?.cancel()
        mapPrewarmTask = nil
    }

    // MARK: Saved journeys

    func isSaved(_ journey: Journey) -> Bool {
        savedJourneys.contains { $0.journey.id == journey.id }
    }

    /// `search` keeps the options the journey was found with (vehicle types, via stops, …) so they
    /// can be picked up again when the route is re-planned from an earlier exit.
    func save(_ journey: Journey, search: ConnectionSearch? = nil) {
        guard !isSaved(journey) else { return }
        if settings.connectionWarnings || settings.exitReminders || settings.stepFree {
            Task { await ConnectionNotifier.requestAuthorization() }
        }
        // One assignment, so the list is persisted and synced once rather than twice.
        var updated = savedJourneys
        updated.append(SavedJourney(journey: journey, search: search))
        updated.sort(by: SavedJourney.departsEarlier)
        savedJourneys = updated
    }

    /// What saving `journey` warns about: the trains bahn.de lists as reservation-only (a seat reservation is
    /// mandatory) and, with a normal `bike`, those it only comes along on with a bike reservation or not at all (#398).
    /// Answers within `limit`: a train bahn.de doesn't know, or doesn't answer for in time, counts as free of a seat
    /// reservation and gets the bike rules alone (`BikeTransport.resolved`), so saving never waits long. The lookups
    /// stay cached, so a second try is instant.
    func saveWarnings(for journey: Journey, bike: BikeOption?, within limit: Duration = .seconds(3)) async -> SaveWarnings {
        let legs = journey.transitLegs
        let checksBike = bike == .bike
        var answers: [String: (seat: Bool, bike: BikeTransport?)] = [:]
        if let bahnDe = provider.bahnDe {
            answers = await withTaskGroup(of: [String: (seat: Bool, bike: BikeTransport?)]?.self) { group in
                group.addTask {
                    await withTaskGroup(of: (String, Bool, BikeTransport?).self) { lookups in
                        for leg in legs {
                            lookups.addTask {
                                let seat = (try? await bahnDe.requiresReservation(for: leg)) == true
                                var transport: BikeTransport?
                                if checksBike { transport = await self.bikeTransport(for: leg, bike: .bike) }
                                return (leg.id, seat, transport)
                            }
                        }
                        var found: [String: (seat: Bool, bike: BikeTransport?)] = [:]
                        for await (id, seat, transport) in lookups { found[id] = (seat, transport) }
                        return found
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: limit)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? [:]
            }
        }
        var warnings = SaveWarnings()
        for leg in legs {
            if answers[leg.id]?.seat == true { warnings.seatReservation.append(leg) }
            guard checksBike else { continue }
            switch (answers[leg.id]?.bike ?? BikeTransport.resolved(bahnDe: nil, for: leg))?.kind {
            case .reservationRequired: warnings.bikeReservation.append(leg)
            case .notAllowed: warnings.noBikes.append(leg)
            default: break
            }
        }
        return warnings
    }

    /// Whether `bike` can come along on `leg` (#398): bahn.de's answer (cached with the reservation check), whether the
    /// train has bike spaces at all (its Wagenreihung or series, the same lookups the leg shows anyway), else the rules.
    func bikeTransport(for leg: Leg, bike: BikeOption) async -> BikeTransport? {
        guard bike == .bike else { return BikeTransport.resolved(bahnDe: nil, for: leg, bike: bike) }
        let bahnDe = try? await provider.bahnDe?.bikeTransport(for: leg)
        var sequence: CoachSequence?
        var families: [String] = []
        if leg.line?.product.isLongDistance == true {
            if let request = BahnDeClient.formationRequest(for: leg) {
                sequence = try? await coachSequence(for: request)
                families = sequence?.formation.units.compactMap(\.model) ?? []
            }
            if families.isEmpty { families = rememberedFormation(for: leg)?.units.compactMap(\.model) ?? [] }
            if families.isEmpty, let lookup = await trainType(for: leg.line, on: leg.departure.planned) {
                families = lookup.families
            }
            if sequence?.coaches.isEmpty != false, let request = BahnDeClient.formationRequest(for: leg, lookahead: nil) {
                sequence = await plannedCoachSequence(for: request, direction: false)
            }
        }
        let hasSpaces = BikeTransport.hasBikeSpaces(line: leg.line, families: families, sequence: sequence)
        return BikeTransport.resolved(bahnDe: bahnDe, for: leg, bike: bike, hasBikeSpaces: hasSpaces)
    }

    func unsave(_ journey: Journey) {
        let removed = Set(savedJourneys.filter { $0.journey.id == journey.id }.map(\.id))
        savedJourneys.removeAll { $0.journey.id == journey.id }
        for ticket in tickets where ticket.journeyID.map(removed.contains) ?? false { removeTicket(ticket) }
    }

    var upcomingJourneys: [SavedJourney] {
        savedJourneys.filter { !$0.isFinished }
            .sorted { ($0.journey.departure?.planned ?? .distantFuture) < ($1.journey.departure?.planned ?? .distantFuture) }
    }

    func savedEntry(for journey: Journey) -> SavedJourney? {
        savedJourneys.first { $0.journey.id == journey.id }
    }

    /// Replaces a saved journey with an alternative and keeps the old plan. `search` updates the
    /// stored search options when the replacement was planned with different ones.
    func replaceSaved(id: UUID, with journey: Journey, reason: String, search: ConnectionSearch? = nil) {
        guard let index = savedJourneys.firstIndex(where: { $0.id == id }) else { return }
        var entry = savedJourneys[index]
        let old = PlanVersion(journey: entry.journey, replacedAt: .now, reason: reason)
        entry.previousVersions = [old] + (entry.previousVersions ?? [])
        entry.journey = journey
        entry.notifiedIssues = []
        if let search { entry.search = search }
        savedJourneys[index] = entry
    }

    // MARK: Realtime refresh & warnings

    /// How often realtime data of saved journeys and their trip views is refreshed.
    static let realtimeRefreshInterval: Duration = .seconds(300)

    /// Whether any saved journey rides the trip `id`, so its trip view should keep itself fresh.
    func isTripSaved(_ id: String) -> Bool {
        savedJourneys.contains { $0.journey.legs.contains { $0.tripId == id } }
    }

    // MARK: Live train positions

    /// Latest position of every train on a saved journey that is running right now, keyed by train name.
    private(set) var trainPositions: [String: LiveTrainPosition] = [:] {
        didSet { if trainPositions != oldValue { updateWidgets() } }
    }
    /// What the widgets were last given, so they're only reloaded when something changed.
    @ObservationIgnored var lastWidgetSnapshot: WidgetSnapshot?
    @ObservationIgnored var lastWidgetStations: WidgetStations?

    /// Fetches the position of each train leg of an unfinished saved journey that is underway
    /// (plus 10 minutes either side, since departures and arrivals shift). All legs share one
    /// bahn.jetzt request, and nothing is requested while no train is running.
    func refreshTrainPositions() async {
        guard let bahnJetzt = provider.bahnJetzt else { return }
        let now = Date.now
        let legs = upcomingJourneys.flatMap(\.journey.transitLegs).filter { leg in
            BahnJetztClient.supports(leg.line) && !leg.cancelled
                && leg.departure.best.addingTimeInterval(-600) <= now && now <= leg.arrival.best.addingTimeInterval(600)
        }
        guard !legs.isEmpty else {
            trainPositions = [:]
            return
        }
        var found: [String: LiveTrainPosition] = [:]
        await withTaskGroup(of: LiveTrainPosition?.self) { group in
            for leg in legs {
                group.addTask {
                    guard let name = leg.line?.name, let position = try? await bahnJetzt.position(for: leg) else { return nil }
                    return LiveTrainPosition(trainName: name, position: position)
                }
            }
            for await live in group {
                if let live { found[live.trainName] = live }
            }
        }
        // A failed refresh (offline, bahn.jetzt pausing) keeps the last positions; they turn stale on the map.
        for (name, live) in trainPositions where found[name] == nil && legs.contains(where: { $0.line?.name == name }) {
            found[name] = live
        }
        trainPositions = found
    }

    /// Keeps `trainPositions` fresh for as long as the calling task runs — the map, the only place
    /// positions are shown, runs this while it is on screen, so nothing is downloaded otherwise.
    func followTrainPositions() async {
        await repeatingAtPositionInterval { await self.refreshTrainPositions() }
    }

    /// Runs `body` at the interval picked in the settings (`TrainPositionRefresh`, which may depend on
    /// mobile data or Low Data Mode) until the calling task is cancelled. With refreshing switched off,
    /// `body` runs once and again only after it is switched back on.
    private func repeatingAtPositionInterval(_ body: () async -> Void) async {
        let monitor = NWPathMonitor()
        monitor.start(queue: .global(qos: .utility))
        defer { monitor.cancel() }
        var fetchesNext = true
        while !Task.isCancelled {
            if fetchesNext { await body() }
            let path = monitor.currentPath
            guard let interval = settings.trainPositionRefresh.interval(savingData: path.isExpensive || path.isConstrained) else {
                fetchesNext = false
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            fetchesNext = true
            try? await Task.sleep(for: interval)
        }
    }

    /// Where one train is right now, from bahn.jetzt; nil while it isn't running (or not in its list).
    func livePosition(of route: LiveTrainRoute) async throws -> TrainPosition? {
        guard let bahnJetzt = provider.bahnJetzt else { return nil }
        return try await bahnJetzt.position(of: route.line, plannedDeparture: route.plannedDeparture, route: route.hint)
    }

    /// Keeps reporting the positions of a journey's running trains for as long as the calling task
    /// runs (the journey map). All legs share one bahn.jetzt list, and nothing is fetched while none
    /// of them may be running.
    func followPositions(of legs: [Leg], update: ([LiveTrainPosition]) -> Void) async {
        let legs = legs.filter { !$0.isWalking && !$0.cancelled && BahnJetztClient.supports($0.line) }
        guard !legs.isEmpty else { return }
        await repeatingAtPositionInterval {
            let running = legs.map(LiveTrainRoute.init(leg:)).filter { $0.mayBeRunning() }
            guard !running.isEmpty else { return update([]) }
            var found: [LiveTrainPosition] = []
            for route in running {
                guard let name = route.line?.name, let position = try? await livePosition(of: route) else { continue }
                found.append(LiveTrainPosition(trainName: name, position: position))
            }
            update(found)
        }
    }

    /// Keeps reporting one train's position for as long as the calling task runs (the live map of a
    /// single train). A failed refresh reports nothing, so the last position stays and turns stale.
    func followPosition(of route: LiveTrainRoute, update: (TrainPosition?) -> Void) async {
        await repeatingAtPositionInterval {
            do {
                update(try await livePosition(of: route))
            } catch {}
        }
    }

    /// Series, Triebzug numbers and names of a train from bahn.de's coach sequence. bahn.de caches
    /// and throttles these itself; nil while there's no coach sequence (yet).
    func formation(for request: BahnDeClient.FormationRequest) async throws -> TrainFormation? {
        guard let bahnDe = provider.bahnDe else { return nil }
        return try await bahnDe.formation(request)
    }

    /// The train's coach sequence ("Wagenreihung") at the request's station. Shares bahn.de's
    /// response with `formation(for:)`.
    func coachSequence(for request: BahnDeClient.FormationRequest) async throws -> CoachSequence? {
        #if DEBUG
        if let demo = debugCoachSequence(for: request) { return demo }
        #endif
        guard let bahnDe = provider.bahnDe else { return nil }
        return try await bahnDe.coachSequence(request)
    }

    /// The seat saved on the train `leg` rides (#410), if any.
    func savedSeat(for leg: Leg) -> SavedSeat? {
        savedSeats.first { $0.belongs(to: leg) }
    }

    /// Saves `seat` for `leg`, or forgets the one there when nil.
    func saveSeat(_ seat: SavedSeat?, for leg: Leg) {
        savedSeats = SavedSeat.saving(seat, for: leg, in: savedSeats)
    }

    /// Where to board each leg of `journey` for a quick transfer or exit (#383), by leg ID (see
    /// `CoachAdvice.plan`): the journey's tickets give the seat reservations and the class, a saved seat
    /// counts like a reserved one.
    func coachAdvice(for journey: Journey) async -> [String: CoachAdvice] {
        var reservations: [String: CoachAdvice.Reservation] = [:]
        for leg in journey.legs {
            if let seat = reservation(for: leg, in: journey) {
                reservations[leg.id] = (seat.coach, seat.trainName)
            } else if let saved = savedSeat(for: leg) {
                reservations[leg.id] = (saved.coach, saved.trainName)
            }
        }
        // A saved ticket says which class; else the one picked in the settings.
        let travelClass = tickets(for: journey).lazy.compactMap(\.ticket.travelClass).first ?? settings.travelClass.number
        return await CoachAdvice.plan(for: journey, reservations: reservations, travelClass: travelClass,
                                      sequence: { [weak self] request in try? await self?.coachSequence(for: request) },
                                      stops: { [weak self] leg in await self?.runStops(of: leg) })
    }

    /// Every stop of `leg`'s train run, from the trips seen live or loaded; nil when it can't be loaded.
    private func runStops(of leg: Leg) async -> [Stopover]? {
        #if DEBUG
        if let demo = debugRunStops(of: leg) { return demo }
        #endif
        guard let tripId = leg.tripId else { return nil }
        if let trip = liveTrips.value(for: tripId) { return trip.stopovers }
        return try? await provider.trip(id: tripId, source: leg.source).stopovers
    }

    /// The formation remembered for a saved journey's leg, or for a Träwelling check-in of the same
    /// train, if any.
    func rememberedFormation(for leg: Leg) -> TrainFormation? {
        rememberedFormations(for: [leg])[0]
    }

    /// `rememberedFormation(for:)` for each of `legs`, collecting the saved formations once.
    func rememberedFormations(for legs: [Leg]) -> [TrainFormation?] {
        let remembered: [(legs: [Leg], formations: [String: TrainFormation])] = savedJourneys.compactMap { saved in
            guard let formations = saved.formations, !formations.isEmpty else { return nil }
            return (legs: saved.journey.legs, formations: formations)
        }
        return legs.map { RideMatch.rememberedFormation(for: $0, in: remembered) }
    }

    /// Keeps a leg's formation in every saved journey riding it, so its Tz and Taufname (or at least
    /// its planned series) stay known (and sync through iCloud) once the train has run.
    func rememberFormation(_ formation: TrainFormation, for leg: Leg) {
        let key = leg.formationKey
        var updated = savedJourneys
        var changed = false
        for index in updated.indices where updated[index].journey.legs.contains(where: { $0.formationKey == key }) {
            if let formations = TrainFormation.remembering(formation, for: key, in: updated[index].formations) {
                updated[index].formations = formations
                changed = true
            }
        }
        if changed { savedJourneys = updated }
    }

    @ObservationIgnored private var trainTypeCache: [String: TrainTypeLookup?] = [:]

    /// A train's type ("ICE 4", "ICE 3neo" …) from its planned formation: vagonweb.cz's scheduled
    /// composition first, bahn.expert (which also has the Tz once DB assigns one) when vagonweb has
    /// nothing. Only the fallback when bahn.de's coach sequence (`formation(for:)`) has nothing.
    /// Cached per train and day; failed requests are not cached so they are retried.
    func trainType(for line: Line?, on date: Date) async -> TrainTypeLookup? {
        guard let ref = BahnDeClient.trainReference(for: line) else { return nil }
        let day = BahnDeClient.berlinDay(date)
        let key = "\(ref.category) \(ref.number)|\(day)"
        if let cached = trainTypeCache[key] { return cached }
        if let vagonweb = provider.vagonweb {
            do {
                if var lookup = try await vagonweb.trainType(category: ref.category, number: ref.number, on: date) {
                    // vagonweb only has the plan, without Tz numbers. Around the day of the ride
                    // bahn.expert has DB's live assignment, which names the Tz and so tells a
                    // redesigned ICE 3neo apart ("ICE 3neo Redesign" for Tz 8039).
                    if !lookup.hasUnitNumbers, abs(date.timeIntervalSinceNow) < 36 * 3600,
                       let live = try? await provider.bahnExpert?.trainType(category: ref.category, number: ref.number, date: day),
                       live.hasUnitNumbers {
                        lookup = live
                    }
                    trainTypeCache[key] = .some(lookup)
                    return lookup
                }
                VagonwebBrowser.log.info("No ICE series for \(ref.category, privacy: .public) \(ref.number, privacy: .public) on \(day, privacy: .public)")
            } catch {
                VagonwebBrowser.log.error("Train type of \(ref.category, privacy: .public) \(ref.number, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        guard let bahnExpert = provider.bahnExpert,
              let lookup = try? await bahnExpert.trainType(category: ref.category, number: ref.number, date: day) else { return nil }
        trainTypeCache[key] = .some(lookup)
        return lookup
    }

    /// The planned Wagenreihung from vagonweb.cz, for when bahn.de has no coach sequence (yet), e.g.
    /// days ahead. Without platform positions; vagonweb caches its pages itself.
    /// Turned round where the train changes direction on the way (Kopfbahnhof, or vagonweb's note); for
    /// that the train's stops before the request's station are needed, from the request or its trip.
    /// - Parameter direction: false when only the coaches matter (comparing with bahn.de's sequence).
    func plannedCoachSequence(for request: BahnDeClient.FormationRequest, direction: Bool = true) async -> CoachSequence? {
        var route: [String]?
        if direction, let before = await stopsBefore(request) { route = before + [request.station.name] }
        do {
            let sequence = try await provider.vagonweb?.coachSequence(for: request, route: route)
            VagonwebBrowser.log.info("Plan-Wagenreihung \(request.category, privacy: .public) \(request.number, privacy: .public): \(sequence.map { "\($0.coaches.count) Wagen" } ?? "keine", privacy: .public)")
            return sequence
        } catch {
            VagonwebBrowser.log.error("Plan-Wagenreihung \(request.category, privacy: .public) \(request.number, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @ObservationIgnored private var tripStopNames: [String: [String]] = [:]

    /// The train's stops before the request's station: from the request, else from its trip (a leg
    /// starts mid-run), loaded once per trip.
    private func stopsBefore(_ request: BahnDeClient.FormationRequest) async -> [String]? {
        if let before = request.stopsBefore { return before }
        guard let tripId = request.tripId, let source = request.tripSource else { return nil }
        var trip = liveTrips.value(for: tripId)
        if trip == nil, tripStopNames[tripId] == nil {
            trip = try? await provider.trip(id: tripId, source: source)
        }
        if let trip { tripStopNames[tripId] = trip.stopovers.map(\.station.name) }
        guard let names = tripStopNames[tripId] else { return nil }
        let key = VagonwebClient.stationKey(request.station.name)
        guard let index = names.firstIndex(where: { VagonwebClient.stationKey($0) == key }) else { return nil }
        return Array(names[..<index])
    }

    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var liveActivitySyncLoop: Task<Void, Never>?
    @ObservationIgnored private var liveJourneyRefreshLoop: Task<Void, Never>?

    /// When the journey in the Live Activity should be refreshed next (see
    /// `LiveActivityRefreshSchedule`: every 2 minutes, around each arrival, every minute while
    /// transferring). Nil if no journey is live.
    var nextLiveJourneyRefresh: Date? {
        guard let activeID = liveActivities.activeJourneyID,
              let entry = upcomingJourneys.first(where: { $0.journey.id == activeID }) else { return nil }
        return LiveActivityRefreshSchedule.nextRefresh(for: entry.journey, after: .now)
    }

    /// Refreshes upcoming journeys and manual Träwelling check-ins every 5 minutes while the app is
    /// active, and the Live Activity's journey on its own, tighter schedule.
    func startRefreshing() {
        if refreshLoop == nil {
            refreshLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshSavedJourneys()
                    await self?.refreshManualCheckins()
                    try? await Task.sleep(for: .seconds(300))
                }
            }
        }
        if liveJourneyRefreshLoop == nil {
            liveJourneyRefreshLoop = Task { [weak self] in
                while !Task.isCancelled {
                    let next = self?.nextLiveJourneyRefresh ?? .now.addingTimeInterval(LiveActivityRefreshSchedule.ridingInterval)
                    try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                    guard !Task.isCancelled else { return }
                    await self?.refreshLiveJourney()
                    self?.syncLiveActivity()
                }
            }
        }
        // Much cheaper than the network refresh above (no I/O), so it can run often — this is what
        // keeps the Live Activity's countdown and next-stop delay moving without the countdown
        // freezing at 0:00 until the app is reopened.
        guard liveActivitySyncLoop == nil else { return }
        liveActivitySyncLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncLiveActivity()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopRefreshing() {
        refreshLoop?.cancel()
        refreshLoop = nil
        liveJourneyRefreshLoop?.cancel()
        liveJourneyRefreshLoop = nil
        liveActivitySyncLoop?.cancel()
        liveActivitySyncLoop = nil
    }

    // MARK: Träwelling check-ins

    func rememberCheckin(statusId: Int, leg: Leg) {
        // Keep the list small: legs are only looked up while their journey is still around.
        if checkinStatusIDs.count > 300 { checkinStatusIDs.removeAll() }
        checkinStatusIDs[leg.id] = statusId
    }

    func forgetCheckin(statusId: Int) {
        checkinStatusIDs = checkinStatusIDs.filter { $0.value != statusId }
        trackedManualCheckins.removeAll { $0.statusId == statusId }
    }

    /// Deletes a check-in on Träwelling and forgets it here.
    func deleteCheckin(statusId: Int) async throws {
        try await traewelling.deleteStatus(id: statusId)
        forgetCheckin(statusId: statusId)
    }

    /// The journey's legs checked in from this app, in order.
    func checkins(in journey: Journey) -> [(leg: Leg, statusId: Int)] {
        let journey = savedEntry(for: journey)?.journey ?? journey
        return journey.legs.compactMap { leg in checkinStatusIDs[leg.id].map { (leg: leg, statusId: $0) } }
    }

    /// The checked-in leg of `journey` that is under way, and where checking out now would end it
    /// (`TraewellingClient.earlyExit`). Uses the saved journey's live times.
    func earlyCheckout(in journey: Journey, at now: Date = .now) -> (leg: Leg, statusId: Int, exit: Stopover)? {
        for checkin in checkins(in: journey) {
            if let exit = TraewellingClient.earlyExit(on: checkin.leg, at: now) { return (leg: checkin.leg, statusId: checkin.statusId, exit: exit) }
        }
        return nil
    }

    /// Deletes every check-in of `journey` made from this app.
    func deleteCheckins(in journey: Journey) async throws {
        for checkin in checkins(in: journey) { try await deleteCheckin(statusId: checkin.statusId) }
    }

    /// Checks out of `journey` now: the ride under way ends at the last stop reached (see
    /// `earlyCheckout`), check-ins of legs not yet started are deleted, finished ones stay.
    func checkOutEarly(of journey: Journey, at now: Date = .now) async throws {
        guard let running = earlyCheckout(in: journey, at: now) else { return }
        let status = try await traewelling.status(id: running.statusId)
        try await traewelling.changeDestination(of: status, to: running.exit.station, arrival: running.exit.arrival?.planned)
        forgetCheckin(statusId: running.statusId)
        for checkin in checkins(in: journey) where checkin.leg.departure.best > now {
            try await deleteCheckin(statusId: checkin.statusId)
        }
    }

    /// The logged-in Träwelling account, nil when logged out or it can't be loaded.
    func traewellingUser() async -> TraewellingUser? {
        guard await traewelling.isLoggedIn else { return nil }
        return try? await traewelling.currentUser()
    }

    /// The custom emojis of the Mastodon instance connected to the Träwelling account `user`, or of
    /// zug.network without one. Empty if neither can be loaded; emojis are only a nicety.
    func checkinEmojis(for user: TraewellingUser?) async -> [CustomEmoji] {
        let instance = CustomEmojiText.instance(fromMastodonURL: user?.mastodonUrl) ?? CustomEmojiText.defaultInstance
        return (try? await customEmojis.emojis(instance: instance)) ?? []
    }

    // MARK: Manual Träwelling check-ins

    /// Replaces a check-in by one on a manual trip that ends at `leg`'s exit, a stop Träwelling's
    /// trip doesn't have (see `TraewellingClient.replaceWithManualTrip`), and keeps its delay updated
    /// like any other manual trip.
    func replaceCheckinWithManualTrip(_ status: TraewellingStatus, leg: Leg) async throws {
        let result = try await traewelling.replaceWithManualTrip(status, leg: leg)
        forgetCheckin(statusId: status.id)
        guard let statusId = result.statusId else { return }
        rememberCheckin(statusId: statusId, leg: leg)
        trackManualCheckin(statusId: statusId, leg: leg)
    }

    func trackManualCheckin(statusId: Int, leg: Leg) {
        trackedManualCheckins.removeAll { $0.leg.id == leg.id }
        trackedManualCheckins.append(TrackedManualCheckin(statusId: statusId, leg: leg, lastUpdate: .distantPast))
    }

    /// Keeps a tracked manual check-in pointed at the ride the user actually made after its exit
    /// was moved, so further delay updates use the new arrival.
    func updateTrackedCheckin(statusId: Int, leg: Leg) {
        guard let index = trackedManualCheckins.firstIndex(where: { $0.statusId == statusId }) else { return }
        trackedManualCheckins[index] = TrackedManualCheckin(statusId: statusId, leg: leg, lastUpdate: .distantPast)
    }

    /// Pushes the current delay to Träwelling every 10 minutes, plus a final update once the leg has
    /// arrived (after which tracking stops, since a manual trip's schedule never changes again).
    func refreshManualCheckins() async {
        guard !trackedManualCheckins.isEmpty else { return }
        let refresher = journeyRefresher
        for entry in trackedManualCheckins {
            // Give up on anything that never got an update for way too long (e.g. the trip was
            // abandoned) so tracking doesn't grow unbounded.
            if entry.leg.departure.planned.addingTimeInterval(48 * 3600) < .now {
                trackedManualCheckins.removeAll { $0.statusId == entry.statusId }
                continue
            }
            let dueForUpdate = Date.now.timeIntervalSince(entry.lastUpdate) >= 10 * 60 || entry.leg.arrival.best < .now
            guard dueForUpdate else { continue }
            let refreshed = await refresher.refresh(Journey(legs: [entry.leg], source: entry.leg.source))
            guard let leg = refreshed.legs.first else { continue }
            guard (try? await traewelling.updateCheckin(statusId: entry.statusId, departure: leg.departure.actual, arrival: leg.arrival.actual)) != nil
            else { continue }
            guard let index = trackedManualCheckins.firstIndex(where: { $0.statusId == entry.statusId }) else { continue }
            if leg.arrival.best.addingTimeInterval(10 * 60) < .now {
                trackedManualCheckins.remove(at: index)
            } else {
                trackedManualCheckins[index] = TrackedManualCheckin(statusId: entry.statusId, leg: leg, lastUpdate: .now)
            }
        }
    }

    /// Updates realtime data of journeys in the next 24 hours and warns about broken connections.
    func refreshSavedJourneys() async {
        let refresher = journeyRefresher
        let horizon = Date.now.addingTimeInterval(24 * 3600)
        for entry in upcomingJourneys where (entry.journey.departure?.best ?? .distantFuture) < horizon {
            await refresh(entry, using: refresher)
        }
    }

    /// Refreshes only the journey currently shown in the Live Activity (if any), so its realtime
    /// data can be kept fresher than the other saved journeys' without refetching all of them.
    func refreshLiveJourney() async {
        guard let activeID = liveActivities.activeJourneyID,
              let entry = upcomingJourneys.first(where: { $0.journey.id == activeID }) else { return }
        await refresh(entry, using: journeyRefresher)
    }

    /// Fetches realtime data for one saved journey, stores it and sends notifications for new issues.
    func refresh(_ entry: SavedJourney, using refresher: JourneyRefresher) async {
        let refreshed = await refresher.refresh(entry.journey)
        // The refresh takes seconds; if the user replanned meanwhile (same entry ID, new journey),
        // this result belongs to the old plan and must neither overwrite nor notify. The next
        // refresh picks up the new plan.
        guard let index = stillSavedIndex(of: entry) else { return }
        var updated = savedJourneys[index]
        let previous = updated.journey
        updated.journey = refreshed
        // DB's dispatchers decided whether a connecting train waits (from bahn.expert); also named in the exit reminders.
        let dispositions = settings.connectionWarnings || settings.exitReminders
            ? await (provider.bahnExpert?.dispositions(in: refreshed) ?? []) : []
        for update in dispositions { transferDispositions[update.departing.id] = update.disposition }
        if settings.connectionWarnings {
            let known = Set(updated.notifiedIssues ?? [])
            // A regular trip's day (#397) stays quiet while its trains run fine; when the push Worker looks
            // after it, cancellations, delays, platform changes and transfers come from there instead.
            let commute = updated.commute
            let reportedByWorker = commute != nil && commutePushWatched.contains(updated.id.uuidString)
            let newIssues = reportedByWorker ? [] : refreshed.connectionIssues().filter { !known.contains($0.id) }
            for issue in newIssues {
                await ConnectionNotifier.notify(issue, journey: refreshed)
            }
            var newDelays: [CommuteDelay] = []
            if let commute, !reportedByWorker {
                newDelays = CommuteAlerts.delays(in: refreshed, threshold: commute.delayThreshold, notified: Array(known))
            }
            for delay in newDelays {
                await ConnectionNotifier.notify(delay)
            }
            // New delay reasons from DB ("Reparatur an einem Signal") get a notification too;
            // plain notices (no WLAN, missing coach) only show as the yellow triangle.
            let newReasons = refreshed.transitLegs.flatMap { leg in
                leg.messages.filter { $0.kind == .delay }.map { (id: "reason|\(leg.id)|\($0.text)", leg: leg, message: $0) }
            }.filter { reason in
                !known.contains(reason.id) && (commute.map { CommuteAlerts.isLateEnough(reason.leg, threshold: $0.delayThreshold) } ?? true)
            }
            for reason in newReasons {
                await ConnectionNotifier.notify(reason.message, leg: reason.leg, id: reason.id)
            }
            // Platform changes for departures and arrivals within the next two hours, incl. transfers.
            let newPlatforms = reportedByWorker ? [] : refreshed.platformChanges(since: previous).filter { !known.contains($0.id) }
            for change in newPlatforms {
                await ConnectionNotifier.notify(change, journey: refreshed)
            }
            let newDispositions = dispositions
                .filter { $0.notificationID.map { !known.contains($0) } ?? false }
            for update in newDispositions {
                await ConnectionNotifier.notify(update, journey: refreshed)
            }
            updated.notifiedIssues = Array(known.union(newIssues.map(\.id)).union(newReasons.map(\.id))
                .union(newPlatforms.map(\.id)).union(newDispositions.compactMap(\.notificationID))
                .union(newDelays.map(\.notificationID)))
        }
        // A lift the journey needs that is out of order (#486), once per lift and place.
        if settings.stepFree {
            let known = Set(updated.notifiedIssues ?? [])
            let newLifts = await liftAlerts(for: refreshed).filter { !known.contains($0.id) }
            for alert in newLifts {
                await ConnectionNotifier.notify(alert, journey: refreshed)
            }
            if !newLifts.isEmpty { updated.notifiedIssues = Array(known.union(newLifts.map(\.id))) }
        }
        // The notifications above await too, so check again before storing.
        guard let storeIndex = stillSavedIndex(of: entry) else { return }
        if updated != savedJourneys[storeIndex] { savedJourneys[storeIndex] = updated }
        await scheduleExitReminderSync(after: .zero).value
        await notifyPassengerRights(for: entry.id)
    }

    /// Where `entry` is saved, provided it still holds the journey it had when it was handed to a
    /// refresh (`replaceSaved` keeps the entry ID but swaps the journey).
    private func stillSavedIndex(of entry: SavedJourney) -> Int? {
        savedJourneys.firstIndex { $0.id == entry.id && $0.journey.id == entry.journey.id }
    }

    /// Past journeys; once their live data is gone (`SavedJourney.liveDataLifetime`) shown as planned,
    /// without any delay.
    var pastJourneys: [SavedJourney] {
        savedJourneys.filter(\.isFinished).sorted { SavedJourney.departsEarlier($1, $0) }.map { entry in
            guard let arrival = entry.journey.arrival?.planned,
                  arrival.addingTimeInterval(SavedJourney.liveDataLifetime) < .now else { return entry }
            var entry = entry
            entry.journey = entry.journey.droppingActualTimes()
            return entry
        }
    }

    /// Upcoming journeys within their Live Activity window: from 30 minutes before departure until
    /// `TripActivityAttributes.arrivedDisplayDuration` after arriving. Only one of these is ever
    /// shown at a time (see `syncLiveActivity`).
    var liveActivityEligibleJourneys: [SavedJourney] {
        let now = Date.now
        return upcomingJourneys.filter {
            !dismissedLiveActivityJourneyIDs.contains($0.id)
                && ($0.journey.departure?.best ?? .distantFuture).addingTimeInterval(-30 * 60) <= now
                && ($0.journey.arrival?.best ?? .distantFuture).addingTimeInterval(TripActivityAttributes.arrivedDisplayDuration) > now
        }
    }

    func isLiveActivityEligible(_ journey: Journey) -> Bool {
        liveActivityEligibleJourneys.contains { $0.journey.id == journey.id }
    }

    /// Shows the Live Activity for whichever journey should currently be live:
    /// - a manual pick from the route view wins as long as that journey has started;
    /// - otherwise, whatever's already showing keeps going until it finishes — a later-added
    ///   journey never interrupts one that's under way, it waits its turn;
    /// - otherwise, the most recently added journey among the ones that have started.
    func syncLiveActivity() {
        if let manualID = manualLiveActivityJourneyID, !upcomingJourneys.contains(where: { $0.id == manualID }) {
            manualLiveActivityJourneyID = nil
            return // the didSet above already re-runs this
        }
        let candidate = liveJourneyCandidate
        // Switched off in the settings: `show(nil)` ends whatever is still running.
        let journey = settings.liveActivitiesEnabled ? candidate?.journey : nil
        Task { await liveActivities.show(journey, pushUpdates: settings.liveActivityServerUpdates) }
        updateWidgets()
    }

    /// The journey that should be live right now (see `syncLiveActivity`), whether or not Live
    /// Activities are switched on; the widgets follow it too.
    var liveJourneyCandidate: SavedJourney? {
        let eligible = liveActivityEligibleJourneys
        if let manualID = manualLiveActivityJourneyID, let manual = eligible.first(where: { $0.id == manualID }) {
            return manual
        } else if let activeID = liveActivities.activeJourneyID, let current = eligible.first(where: { $0.journey.id == activeID }) {
            return current
        }
        return eligible.max { $0.savedAt < $1.savedAt }
    }

    /// Identifier for the background refresh task that keeps the Live Activity's journey up to date
    /// and ends the activity once it finishes while the app is backgrounded (see
    /// `scheduleLiveActivityBackgroundCheck`). Must match an entry in
    /// `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let liveActivityBackgroundTaskID = "de.goldkunibert.BetterBahn.endLiveActivity"

    /// Schedules a background wake-up for the live journey's next refresh (or for shortly after it
    /// is expected to finish, if that's sooner), since the refresh loops only
    /// run in the foreground. iOS decides when the task actually runs, so this is a lower bound.
    /// No-op if no journey is currently live. Called when the app backgrounds.
    func scheduleLiveActivityBackgroundCheck() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.liveActivityBackgroundTaskID)
        guard let activeID = liveActivities.activeJourneyID,
              let entry = savedJourneys.first(where: { $0.journey.id == activeID }),
              let arrival = entry.journey.arrival?.best else { return }
        // Matches the end of the Live Activity window in `liveActivityEligibleJourneys`, plus a small
        // buffer so the eligibility check has already flipped by the time the task runs.
        let finishCheck = arrival.addingTimeInterval(TripActivityAttributes.arrivedDisplayDuration + 30)
        guard finishCheck > .now else { return }
        let fireDate = min(finishCheck, LiveActivityRefreshSchedule.nextRefresh(for: entry.journey, after: .now))
        let request = BGAppRefreshTaskRequest(identifier: Self.liveActivityBackgroundTaskID)
        request.earliestBeginDate = fireDate
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancelLiveActivityBackgroundCheck() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.liveActivityBackgroundTaskID)
    }

    /// Runs when the background task fires: refreshes the live journey, re-evaluates eligibility
    /// (ending the Live Activity if it's now finished), and reschedules for whatever's live
    /// afterwards — e.g. if realtime data pushed the arrival back, or another journey took over.
    func handleLiveActivityBackgroundTask(_ task: BGAppRefreshTask) {
        let work = Task {
            await refreshLiveJourney()
            syncLiveActivity()
            scheduleLiveActivityBackgroundCheck()
            // Our server goes on from what was just loaded (or lets go of an activity that has ended).
            await handOverLiveActivity()
            task.setTaskCompleted(success: true)
        }
        // `@Sendable` keeps the closure nonisolated: a plain closure here would inherit MainActor and
        // crash on the assertion if iOS calls the expiration handler from another queue.
        let cancelWork: @Sendable () -> Void = { work.cancel() }
        task.expirationHandler = cancelWork
    }

    // MARK: Live Activity push updates (#315)

    /// The Live Activity's sign-up at the `betterbahn-live` Worker, while the app is in the background.
    @ObservationIgnored var liveActivityPush: LiveActivityPushRegistration? = Storage.load(key: "liveActivityPush") {
        didSet { Storage.save(liveActivityPush, key: "liveActivityPush") }
    }
    /// Hand-overs and take-backs run one after the other, so opening the app right away can't overtake a hand-over.
    @ObservationIgnored private var liveActivityPushQueue: Task<Void, Never>?

    /// Hands the Live Activity to our server when the app goes to the background: it keeps the delays, platforms
    /// and next stop current with push updates until the app is opened again (`LiveActivityPush`). Without an
    /// activity to hand over (setting off, none running, no push token yet), an earlier sign-up ends.
    func handOverLiveActivity() async {
        await enqueueLiveActivityPush { [self] in
            let entry = settings.liveActivitiesEnabled && settings.liveActivityServerUpdates ? liveJourneyCandidate : nil
            guard let entry, let pushToken = liveActivities.pushToken(for: entry.journey.id) else {
                await endLiveActivityPush()
                return
            }
            if liveActivityPush.map({ $0.journeyID != entry.journey.id }) == true { await endLiveActivityPush() }
            let registration = liveActivityPush ?? LiveActivityPushRegistration(journeyID: entry.journey.id)
            liveActivityPush = registration
            try? await LiveActivityPush().register(registration, pushToken: pushToken, sandbox: Self.pushUsesSandbox,
                                                    journey: LiveActivityPushJourney(entry.journey))
        }
    }

    /// Takes the Live Activity back when the app is open: from then on the app updates it itself.
    func takeBackLiveActivity() async {
        await enqueueLiveActivityPush { [self] in await endLiveActivityPush() }
    }

    private func endLiveActivityPush() async {
        guard let registration = liveActivityPush else { return }
        // Offline the sign-up is kept and ended next time; the server forgets it after the arrival anyway.
        if (try? await LiveActivityPush().unregister(registration)) != nil, liveActivityPush == registration {
            liveActivityPush = nil
        }
    }

    private func enqueueLiveActivityPush(_ work: @escaping @MainActor () async -> Void) async {
        let previous = liveActivityPushQueue
        let task = Task {
            await previous?.value
            await work()
        }
        liveActivityPushQueue = task
        await task.value
    }

    func rememberStation(_ station: Station) {
        recentStations.removeAll { $0.isSamePlace(as: station) }
        recentStations.insert(station, at: 0)
        recentStations = Array(recentStations.prefix(10))
    }

    func remember(from: Station, to: Station) {
        recentSearches.removeAll { $0.from.isSamePlace(as: from) && $0.to.isSamePlace(as: to) }
        recentSearches.insert(RecentSearch(from: from, to: to), at: 0)
        recentSearches = Array(recentSearches.prefix(8))
    }
}

nonisolated struct ImportedTrip: Codable, Hashable, Identifiable {
    var id: Int { statusID }
    var statusID: Int
    var journey: Journey

    /// The trips without their track geometry, plus that geometry by leg ID for the geometry cache.
    static func movingGeometryOut(of trips: [ImportedTrip]) -> ([ImportedTrip], [String: [Coordinate]]) {
        var geometries: [String: [Coordinate]] = [:]
        let stripped = trips.map { trip in
            var trip = trip
            for index in trip.journey.legs.indices {
                guard let geometry = trip.journey.legs[index].geometry else { continue }
                geometries[trip.journey.legs[index].id] = geometry
                trip.journey.legs[index].geometry = nil
            }
            return trip
        }
        return (stripped, geometries)
    }
}

/// A manual Träwelling check-in whose delay we keep pushing until it arrives.
struct TrackedManualCheckin: Codable, Identifiable {
    var id: Int { statusId }
    var statusId: Int
    var leg: Leg
    var lastUpdate: Date
}

/// An earlier version of a saved journey, kept when an alternative was chosen.
nonisolated struct PlanVersion: Codable, Hashable, Identifiable {
    var id = UUID()
    var journey: Journey
    var replacedAt: Date
    var reason: String
}

nonisolated struct SavedJourney: Codable, Hashable, Identifiable {
    var id = UUID()
    var journey: Journey
    var savedAt = Date.now
    /// The search this journey came from, if known – used to pre-fill a re-plan with the same
    /// vehicle types, via stops and limits (optional so older saved data still decodes).
    var search: ConnectionSearch?
    /// Older plans, newest first (optional so older saved data still decodes).
    var previousVersions: [PlanVersion]?
    /// Issue IDs we already sent a notification for.
    var notifiedIssues: [String]?
    /// Trainsets (Tz, Taufname) seen on the legs' trains, keyed by `Leg.formationKey`, kept and
    /// synced so they stay known after the journey (optional so older saved data still decodes).
    var formations: [String: TrainFormation]?
    /// The Fahrgastrechte claim seen when the journey arrived (#311), kept so it stays after the live
    /// data is gone (optional so older saved data still decodes).
    var recordedClaim: PassengerRightsClaim?
    /// The exit reminders (#313) are switched off for this journey (optional so older saved data still decodes).
    var exitRemindersOff: Bool?
    /// Set when the journey is a regular trip's day (#397): it then only reports problems.
    var commute: CommuteDay?

    var issues: [ConnectionIssue] { journey.currentIssues() }

    /// How long after arriving a finished journey is still refreshed when opened.
    static let liveDataLifetime: TimeInterval = 24 * 3600

    /// Finished 10 minutes after the (realtime) arrival.
    var isFinished: Bool { journey.isOver() }

    /// The order of `AppModel.savedJourneys`: by planned departure.
    static func departsEarlier(_ a: SavedJourney, _ b: SavedJourney) -> Bool {
        (a.journey.departure?.planned ?? .distantPast) < (b.journey.departure?.planned ?? .distantPast)
    }
}

/// Where a saved journey's train is right now.
struct LiveTrainPosition: Identifiable, Hashable, Sendable {
    var id: String { trainName }
    let trainName: String
    let position: TrainPosition
}

nonisolated struct RecentSearch: Codable, Hashable, Identifiable {
    var id: String { from.id + "→" + to.id }
    var from: Station
    var to: Station
}

/// JSON files in Application Support (saved journeys and route shapes get large).
/// Nonisolated so callers can load/save off the main actor for large files (e.g. route geometry).
nonisolated enum Storage {
    private static var directory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "BetterBahn", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ key: String) -> URL {
        directory.appending(path: key + ".json")
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file(key), options: .atomic)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static let writer = DispatchQueue(label: "de.goldkunibert.BetterBahn.storage", qos: .userInitiated)

    /// Like `save`, but encodes and writes on a background queue. Writes land in the order they
    /// were made, so the last change always wins.
    static func saveInBackground<T: Encodable & Sendable>(_ value: T, key: String) {
        writer.async { save(value, key: key) }
    }

    /// Moves values older versions kept in UserDefaults into files, as is, without decoding them.
    static func migrateFromUserDefaults(keys: [String]) {
        for key in keys {
            guard let data = UserDefaults.standard.data(forKey: key) else { continue }
            if !FileManager.default.fileExists(atPath: file(key).path()) {
                guard (try? data.write(to: file(key), options: .atomic)) != nil else { continue }
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static let log = Logger(subsystem: "de.goldkunibert.BetterBahn", category: "storage")

    static func load<T: Decodable>(key: String) -> T? {
        // Older versions stored everything in UserDefaults.
        let data = (try? Data(contentsOf: file(key))) ?? UserDefaults.standard.data(forKey: key)
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // An unreadable file (e.g. written by a newer build) would otherwise start the app with
            // an empty list, and the next save would overwrite it. Name the error and keep a copy.
            log.error("\(key, privacy: .public).json is unreadable: \(String(describing: error), privacy: .public)")
            let copy = directory.appending(path: key + ".unreadable.json")
            if !FileManager.default.fileExists(atPath: copy.path()) { try? data.write(to: copy, options: .atomic) }
            return nil
        }
    }
}

@Observable
final class AppSettings {
    /// Whether the "only valid with my ticket" filters start switched on.
    var ticketFilterByDefault: Bool {
        didSet {
            UserDefaults.standard.set(ticketFilterByDefault, forKey: "onlyBC100ByDefault")
            uploadToCloud()
        }
    }
    /// What the user takes along (#398): the search option "Mit Fahrrad"/"Mit Klapprad" only shows for a
    /// folding or normal bike. Hidden by default.
    var bikeOption: BikeOption {
        didSet {
            UserDefaults.standard.set(bikeOption.rawValue, forKey: "bikeOption")
            uploadToCloud()
        }
    }
    /// The bike to show whether it comes along on a search's legs, nil while the search option is off or bikes are hidden.
    func bike(searchingWithBike: Bool) -> BikeOption? {
        searchingWithBike && bikeOption != .hidden ? bikeOption : nil
    }
    /// The search option "Mit Fahrrad" (#398): legs say whether a bike can come along, saving warns about bike
    /// reservations. Kept from one search to the next, off by default.
    var searchWithBike: Bool {
        didSet {
            UserDefaults.standard.set(searchWithBike, forKey: "searchWithBike")
            uploadToCloud()
        }
    }
    /// The ticket those filters check against.
    var ticketType: TicketType {
        didSet {
            UserDefaults.standard.set(ticketType.rawValue, forKey: "ticketType")
            uploadToCloud()
        }
    }
    /// The class the user travels in: DB's occupancy forecast is shown for it (#399).
    var travelClass: TravelClass {
        didSet {
            UserDefaults.standard.set(travelClass.rawValue, forKey: "travelClass")
            uploadToCloud()
        }
    }
    var traewellingVisibility: TraewellingVisibility {
        didSet {
            UserDefaults.standard.set(traewellingVisibility.rawValue, forKey: "traewellingVisibility")
            uploadToCloud()
        }
    }
    var bc100Rules: BC100Rules {
        didSet {
            Storage.save(bc100Rules, key: "bc100Rules")
            uploadToCloud()
        }
    }
    var syncTraewellingToMap: Bool {
        didSet {
            UserDefaults.standard.set(syncTraewellingToMap, forKey: "syncTraewellingToMap")
            uploadToCloud()
        }
    }
    var connectionWarnings: Bool {
        didSet {
            UserDefaults.standard.set(connectionWarnings, forKey: "connectionWarnings")
            uploadToCloud()
        }
    }
    /// A notification shortly before arriving where the user gets off (#313); saved journeys can opt out.
    var exitReminders: Bool {
        didSet {
            UserDefaults.standard.set(exitReminders, forKey: "exitReminders")
            uploadToCloud()
        }
    }
    /// "Stufenfrei reisen" (#486): search results flag journeys that need a lift out of order, saved journeys
    /// notify when one fails and exit reminders name it. Off by default; the warnings in a journey and on the
    /// departure board show anyway.
    var stepFree: Bool {
        didSet {
            UserDefaults.standard.set(stepFree, forKey: "stepFree")
            uploadToCloud()
        }
    }
    var exitReminderLead: ExitReminderLead {
        didSet {
            UserDefaults.standard.set(exitReminderLead.rawValue, forKey: "exitReminderLead")
            uploadToCloud()
        }
    }
    /// What the app may do with the calendar events of saved journeys (#382); nil until the user chose.
    /// Per device, like the calendar access itself.
    var calendarAccess: CalendarAccessMode? {
        didSet { UserDefaults.standard.set(calendarAccess?.rawValue, forKey: "calendarAccess") }
    }
    /// The calendar new journey events go to; nil for the default calendar. Per device, like `calendarAccess`.
    var calendarID: String? {
        didSet { UserDefaults.standard.set(calendarID, forKey: "calendarID") }
    }
    /// Adds saved journeys to the calendar by themselves (off by default). Per device, like `calendarAccess`.
    var calendarAutoAdd: CalendarAutoAdd {
        didSet { UserDefaults.standard.set(calendarAutoAdd.rawValue, forKey: "calendarAutoAdd") }
    }
    /// Notifications when someone the user follows checks in on Träwelling (#266). Per device, like
    /// the permission to show notifications.
    var notifyFollowedCheckins: Bool {
        didSet { UserDefaults.standard.set(notifyFollowedCheckins, forKey: "notifyFollowedCheckins") }
    }
    /// Notifications about likes on the user's own check-ins (#447), per device like `notifyFollowedCheckins`.
    var notifyCheckinLikes: Bool {
        didSet { UserDefaults.standard.set(notifyCheckinLikes, forKey: "notifyCheckinLikes") }
    }
    /// Notifications when someone checks in on the user's train (#447).
    var notifyCheckinCompanions: Bool {
        didSet { UserDefaults.standard.set(notifyCheckinCompanions, forKey: "notifyCheckinCompanions") }
    }
    var lastTraewellingSync: Date? {
        didSet { UserDefaults.standard.set(lastTraewellingSync, forKey: "lastTraewellingSync") }
    }
    /// The history page an unfinished Träwelling import continues with; nil once it reached the oldest check-in.
    var traewellingImportNextPage: Int? {
        didSet { UserDefaults.standard.set(traewellingImportNextPage, forKey: "traewellingImportNextPage") }
    }
    /// Suggested tags offered as quick-add chips in the Träwelling check-in sheet.
    var quickTags: [QuickTag] {
        didSet {
            Storage.save(quickTags, key: "quickTags")
            uploadToCloud()
        }
    }

    /// Shows the next saved journey as a Live Activity on the Lock Screen and in the Dynamic Island.
    var liveActivitiesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivitiesEnabled, forKey: "liveActivitiesEnabled")
            uploadToCloud()
        }
    }

    /// Our server keeps the Live Activity current while the app is closed (#315); it gets the journey for that.
    var liveActivityServerUpdates: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityServerUpdates, forKey: "liveActivityServerUpdates")
            uploadToCloud()
        }
    }

    /// How often maps refresh the positions of running trains. Stays on this device, since the
    /// data it costs depends on the device's connection.
    var trainPositionRefresh: TrainPositionRefresh {
        didSet { UserDefaults.standard.set(trainPositionRefresh.rawValue, forKey: "trainPositionRefresh") }
    }

    /// Whether station search results start with the country's flag (#349). Stays on this device.
    var stationFlagMode: StationFlagMode {
        didSet { UserDefaults.standard.set(stationFlagMode.rawValue, forKey: "stationFlagMode") }
    }

    /// Which kinds of trains the train search (#183) lists.
    var trainSearchKinds: Set<TrainSearchKind> {
        didSet {
            UserDefaults.standard.set(trainSearchKinds.map(\.rawValue).sorted(), forKey: "trainSearchKinds")
            uploadToCloud()
        }
    }
    /// The train search only lists trains running through one of these countries (ISO codes); empty: anywhere.
    var trainSearchCountries: Set<String> {
        didSet {
            UserDefaults.standard.set(trainSearchCountries.sorted(), forKey: "trainSearchCountries")
            uploadToCloud()
        }
    }
    var trainSearchFilter: TrainSearchFilter { TrainSearchFilter(kinds: trainSearchKinds, countries: trainSearchCountries) }

    /// Shows what BetterBahn's statistics server knows about a train: delays, cancellations and platforms
    /// of the last 30 days (`TrainStatisticsStore`, #316). The app reports nothing (#336). On by default, per device.
    var showTrainStatistics: Bool {
        didSet {
            UserDefaults.standard.set(showTrainStatistics, forKey: "showTrainStatistics")
            let enabled = showTrainStatistics
            Task { await TrainStatisticsStore.shared.setEnabled(enabled) }
        }
    }

    /// The weather on arrival and at long transfers in a journey (#385), from Open-Meteo. On by default.
    var showWeather: Bool {
        didSet {
            UserDefaults.standard.set(showWeather, forKey: "showWeather")
            uploadToCloud()
        }
    }

    /// Unlocks the features below; each one still has to be switched on by itself.
    var expertMode: Bool {
        didSet {
            UserDefaults.standard.set(expertMode, forKey: "expertMode")
            uploadToCloud()
        }
    }
    var expertTraewelling: Bool {
        didSet {
            UserDefaults.standard.set(expertTraewelling, forKey: "expertTraewelling")
            uploadToCloud()
        }
    }
    var expertEditJourney: Bool {
        didSet {
            UserDefaults.standard.set(expertEditJourney, forKey: "expertEditJourney")
            uploadToCloud()
        }
    }
    var expertTrainChoice: Bool {
        didSet {
            UserDefaults.standard.set(expertTrainChoice, forKey: "expertTrainChoice")
            uploadToCloud()
        }
    }
    var expertIgnoreBoardingRules: Bool {
        didSet {
            UserDefaults.standard.set(expertIgnoreBoardingRules, forKey: "expertIgnoreBoardingRules")
            uploadToCloud()
        }
    }
    var expertRil100: Bool {
        didSet {
            UserDefaults.standard.set(expertRil100, forKey: "expertRil100")
            uploadToCloud()
        }
    }

    /// Träwelling check-ins, login and map import.
    var traewellingEnabled: Bool { expertMode && expertTraewelling }
    /// Editing a journey: changing the exit or re-planning the rest of the route.
    var editJourneyEnabled: Bool { expertMode && expertEditJourney }
    /// Forcing specific trains into a route or swapping a leg for another train.
    var trainChoiceEnabled: Bool { expertMode && expertTrainChoice }
    /// The connection search also shows direct trains you may not board or leave at that station
    /// ("Nur Ausstieg" / "Nur Einstieg"), which the timetable otherwise hides.
    var ignoreBoardingRulesEnabled: Bool { expertMode && expertIgnoreBoardingRules }
    /// The station search shows each station's RIL100 code ("FF") next to its name (#165). Searching
    /// by code works either way.
    var ril100Enabled: Bool { expertMode && expertRil100 }

    init() {
        let defaults = UserDefaults.standard
        ticketFilterByDefault = defaults.bool(forKey: "onlyBC100ByDefault")
        searchWithBike = defaults.bool(forKey: "searchWithBike")
        bikeOption = defaults.string(forKey: "bikeOption").flatMap(BikeOption.init) ?? .hidden
        ticketType = defaults.string(forKey: "ticketType").flatMap(TicketType.init) ?? .deutschlandticket
        travelClass = defaults.string(forKey: "travelClass").flatMap(TravelClass.init) ?? .second
        liveActivitiesEnabled = defaults.object(forKey: "liveActivitiesEnabled") as? Bool ?? true
        liveActivityServerUpdates = defaults.object(forKey: "liveActivityServerUpdates") as? Bool ?? true
        trainPositionRefresh = defaults.string(forKey: "trainPositionRefresh").flatMap(TrainPositionRefresh.init) ?? .automatic
        stationFlagMode = defaults.string(forKey: "stationFlagMode").flatMap(StationFlagMode.init) ?? .foreignOnly
        // A new key: switching off sharing (#169) said nothing about wanting to see the statistics.
        let showTrainStatistics = defaults.object(forKey: "showTrainStatistics") as? Bool ?? true
        self.showTrainStatistics = showTrainStatistics
        defaults.removeObject(forKey: "shareTrainStatistics")
        Task { await TrainStatisticsStore.shared.setEnabled(showTrainStatistics) }
        showWeather = defaults.object(forKey: "showWeather") as? Bool ?? true
        expertMode = defaults.bool(forKey: "expertMode")
        expertTraewelling = defaults.bool(forKey: "expertTraewelling")
        expertEditJourney = defaults.bool(forKey: "expertEditJourney")
        expertTrainChoice = defaults.bool(forKey: "expertTrainChoice")
        expertIgnoreBoardingRules = defaults.bool(forKey: "expertIgnoreBoardingRules")
        expertRil100 = defaults.bool(forKey: "expertRil100")
        traewellingVisibility = TraewellingVisibility(rawValue: defaults.integer(forKey: "traewellingVisibility")) ?? .publicVisible
        bc100Rules = Storage.load(key: "bc100Rules") ?? .default
        syncTraewellingToMap = defaults.object(forKey: "syncTraewellingToMap") as? Bool ?? true
        notifyFollowedCheckins = defaults.bool(forKey: "notifyFollowedCheckins")
        notifyCheckinLikes = defaults.bool(forKey: "notifyCheckinLikes")
        notifyCheckinCompanions = defaults.bool(forKey: "notifyCheckinCompanions")
        lastTraewellingSync = defaults.object(forKey: "lastTraewellingSync") as? Date
        traewellingImportNextPage = defaults.object(forKey: "traewellingImportNextPage") as? Int
        connectionWarnings = defaults.object(forKey: "connectionWarnings") as? Bool ?? true
        exitReminders = defaults.object(forKey: "exitReminders") as? Bool ?? true
        stepFree = defaults.bool(forKey: "stepFree")
        exitReminderLead = ExitReminderLead(rawValue: defaults.integer(forKey: "exitReminderLead")) ?? .five
        calendarAccess = defaults.string(forKey: "calendarAccess").flatMap(CalendarAccessMode.init)
        calendarID = defaults.string(forKey: "calendarID")
        calendarAutoAdd = defaults.string(forKey: "calendarAutoAdd").flatMap(CalendarAutoAdd.init) ?? .off
        quickTags = Storage.load(key: "quickTags") ?? QuickTag.defaults
        trainSearchKinds = defaults.stringArray(forKey: "trainSearchKinds").map { Set($0.compactMap(TrainSearchKind.init)) }
            ?? TrainSearchKind.defaults
        trainSearchCountries = defaults.stringArray(forKey: "trainSearchCountries").map(Set.init) ?? TrainSearchCountry.defaults
    }

    // MARK: iCloud

    static let cloudKey = "settings"

    /// The settings that sync between devices (not the per-device Träwelling sync date).
    private struct CloudValue: Codable, Equatable {
        var ticketFilterByDefault: Bool
        var ticketType: TicketType
        var traewellingVisibility: TraewellingVisibility
        var bc100Rules: BC100Rules
        var syncTraewellingToMap: Bool
        var connectionWarnings: Bool
        var quickTags: [QuickTag]
        var liveActivitiesEnabled: Bool
        var expertMode: Bool
        var expertTraewelling: Bool
        var expertEditJourney: Bool
        var expertTrainChoice: Bool
        /// Optional: settings synced by older versions don't have it.
        var expertIgnoreBoardingRules: Bool?
        var expertRil100: Bool?
        var trainSearchKinds: [TrainSearchKind]?
        var trainSearchCountries: [String]?
        var exitReminders: Bool?
        var exitReminderLead: ExitReminderLead?
        var liveActivityServerUpdates: Bool?
        var showWeather: Bool?
        var searchWithBike: Bool?
        var bikeOption: BikeOption?
        var travelClass: TravelClass?
        var stepFree: Bool?
    }

    /// What iCloud stores: the settings and when they were last changed.
    private struct CloudSettings: Codable {
        var value: CloudValue
        var changedAt: Date
    }

    private static let defaultCloudValue = CloudValue(
        ticketFilterByDefault: false, ticketType: .deutschlandticket,
        traewellingVisibility: TraewellingVisibility(rawValue: 0) ?? .publicVisible, bc100Rules: .default,
        syncTraewellingToMap: true, connectionWarnings: true, quickTags: QuickTag.defaults,
        liveActivitiesEnabled: true, expertMode: false, expertTraewelling: false, expertEditJourney: false,
        expertTrainChoice: false, expertIgnoreBoardingRules: false, expertRil100: false,
        trainSearchKinds: TrainSearchKind.defaults.sorted(by: { $0.rawValue < $1.rawValue }),
        trainSearchCountries: TrainSearchCountry.defaults.sorted(), exitReminders: true, exitReminderLead: .five,
        liveActivityServerUpdates: true, showWeather: true, searchWithBike: false, bikeOption: .hidden, travelClass: .second,
        stepFree: false)

    @ObservationIgnored private var isApplyingCloudValue = false

    private var cloudValue: CloudValue {
        CloudValue(ticketFilterByDefault: ticketFilterByDefault, ticketType: ticketType,
                   traewellingVisibility: traewellingVisibility, bc100Rules: bc100Rules,
                   syncTraewellingToMap: syncTraewellingToMap, connectionWarnings: connectionWarnings,
                   quickTags: quickTags, liveActivitiesEnabled: liveActivitiesEnabled, expertMode: expertMode,
                   expertTraewelling: expertTraewelling, expertEditJourney: expertEditJourney,
                   expertTrainChoice: expertTrainChoice, expertIgnoreBoardingRules: expertIgnoreBoardingRules,
                   expertRil100: expertRil100,
                   trainSearchKinds: trainSearchKinds.sorted(by: { $0.rawValue < $1.rawValue }),
                   trainSearchCountries: trainSearchCountries.sorted(), exitReminders: exitReminders,
                   exitReminderLead: exitReminderLead, liveActivityServerUpdates: liveActivityServerUpdates,
                   showWeather: showWeather, searchWithBike: searchWithBike, bikeOption: bikeOption,
                   travelClass: travelClass, stepFree: stepFree)
    }

    /// When the settings were last changed on this device or taken over from iCloud. Before
    /// syncing existed there's no date: untouched settings then lose against any synced ones,
    /// changed ones only against settings changed since.
    private var changedAt: Date {
        get {
            UserDefaults.standard.object(forKey: "settingsChangedAt") as? Date
                ?? (cloudValue == Self.defaultCloudValue ? .distantPast : Date(timeIntervalSince1970: 0))
        }
        set { UserDefaults.standard.set(newValue, forKey: "settingsChangedAt") }
    }

    private func uploadToCloud() {
        guard !isApplyingCloudValue else { return }
        changedAt = .now
        CloudSync.upload(CloudSettings(value: cloudValue, changedAt: changedAt), key: Self.cloudKey)
    }

    /// Takes over the settings from iCloud if they were changed later than the ones here,
    /// otherwise uploads these.
    func receiveCloudValue() {
        let local = CloudSettings(value: cloudValue, changedAt: changedAt)
        guard let cloud: CloudSettings = CloudSync.value(key: Self.cloudKey), cloud.changedAt >= local.changedAt else {
            CloudSync.upload(local, key: Self.cloudKey)
            return
        }
        changedAt = cloud.changedAt
        guard cloud.value != local.value else { return }
        let value = cloud.value
        isApplyingCloudValue = true
        defer { isApplyingCloudValue = false }
        ticketFilterByDefault = value.ticketFilterByDefault
        ticketType = value.ticketType
        traewellingVisibility = value.traewellingVisibility
        bc100Rules = value.bc100Rules
        syncTraewellingToMap = value.syncTraewellingToMap
        connectionWarnings = value.connectionWarnings
        quickTags = value.quickTags
        liveActivitiesEnabled = value.liveActivitiesEnabled
        expertMode = value.expertMode
        expertTraewelling = value.expertTraewelling
        expertEditJourney = value.expertEditJourney
        expertTrainChoice = value.expertTrainChoice
        expertIgnoreBoardingRules = value.expertIgnoreBoardingRules ?? expertIgnoreBoardingRules
        expertRil100 = value.expertRil100 ?? expertRil100
        trainSearchKinds = value.trainSearchKinds.map(Set.init) ?? trainSearchKinds
        trainSearchCountries = value.trainSearchCountries.map(Set.init) ?? trainSearchCountries
        exitReminders = value.exitReminders ?? exitReminders
        exitReminderLead = value.exitReminderLead ?? exitReminderLead
        liveActivityServerUpdates = value.liveActivityServerUpdates ?? liveActivityServerUpdates
        showWeather = value.showWeather ?? showWeather
        searchWithBike = value.searchWithBike ?? searchWithBike
        bikeOption = value.bikeOption ?? bikeOption
        travelClass = value.travelClass ?? travelClass
        stepFree = value.stepFree ?? stepFree
    }
}

/// Local notifications for broken connections, new delay reasons and platform changes.
enum ConnectionNotifier {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notify(_ issue: ConnectionIssue, journey: Journey) async {
        let content = UNMutableNotificationContent()
        content.title = issue.title
        let route = [journey.legs.first?.origin.displayName, journey.legs.last?.destination.displayName].compactMap { $0 }.joined(separator: " → ")
        content.body = issue.message + (route.isEmpty ? "" : "\n\(route)")
        content.sound = issue.isBlocking ? .defaultCritical : .default
        content.interruptionLevel = issue.isBlocking ? .timeSensitive : .active
        let request = UNNotificationRequest(identifier: issue.id + journey.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func notify(_ change: PlatformChange, journey: Journey) async {
        let content = UNMutableNotificationContent()
        content.title = change.title
        content.body = change.message
        content.sound = .default
        content.interruptionLevel = change.isTight ? .timeSensitive : .active
        let request = UNNotificationRequest(identifier: change.id + journey.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func notify(_ update: TransferDispositionUpdate, journey: Journey) async {
        guard let disposition = update.disposition, let id = update.notificationID else { return }
        let content = UNMutableNotificationContent()
        content.title = disposition.title
        content.body = disposition.message(arriving: update.arriving, departing: update.departing)
        content.sound = disposition == .notWaiting ? .defaultCritical : .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: id + journey.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// A regular trip's train is late enough to say so (#397).
    static func notify(_ delay: CommuteDelay) async {
        let content = UNMutableNotificationContent()
        content.title = delay.title
        content.body = delay.message
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: delay.notificationID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func notify(_ message: TrainMessage, leg: Leg, id: String) async {
        let content = UNMutableNotificationContent()
        let line = leg.line?.name ?? String(localized: "Zug")
        if let delay = leg.departure.delayMinutes, delay > 0 {
            content.title = String(localized: "\(line): +\(delay) Min.")
        } else {
            content.title = String(localized: "\(line): Verspätungsgrund")
        }
        let since = message.timestamp.map { String(localized: " (seit \($0.timeString))") } ?? ""
        content.body = message.displayText + since + "\n\(leg.origin.displayName) → \(leg.destination.displayName)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// What `AppModel.saveWarnings(for:withBike:)` found before saving a journey.
struct SaveWarnings {
    /// Trains where a seat reservation is mandatory.
    var seatReservation: [Leg] = []
    /// In bike mode: trains a bike only comes along on with a bike reservation.
    var bikeReservation: [Leg] = []
    /// In bike mode: trains that take no bikes.
    var noBikes: [Leg] = []

    var isEmpty: Bool { seatReservation.isEmpty && bikeReservation.isEmpty && noBikes.isEmpty }
}
