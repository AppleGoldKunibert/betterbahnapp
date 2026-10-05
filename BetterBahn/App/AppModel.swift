import BackgroundTasks
import BetterBahnKit
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

    var favoriteStations: [Station] {
        didSet {
            Storage.save(favoriteStations, key: "favoriteStations")
            favoriteStationsCloud.localChange(from: oldValue, to: favoriteStations)
        }
    }
    var recentSearches: [RecentSearch] {
        didSet {
            Storage.save(recentSearches, key: "recentSearches")
            recentSearchesCloud.localChange(from: oldValue, to: recentSearches)
        }
    }
    /// Journeys the user saved. The next upcoming one is shown as Live Activity.
    var savedJourneys: [SavedJourney] {
        didSet {
            Storage.save(savedJourneys, key: "savedJourneys")
            savedJourneysCloud.localChange(from: oldValue, to: savedJourneys)
            syncLiveActivity()
        }
    }
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
    /// Saved journey to open on the Verbindungen tab (set when the Live Activity is tapped);
    /// `ConnectionsView` pushes it and clears this.
    var journeyToOpen: SavedJourney?
    /// Recently picked stations, newest first (used as suggestions).
    var recentStations: [Station] {
        didSet { Storage.save(recentStations, key: "recentStations") }
    }
    /// Manual Träwelling check-ins (trains Träwelling didn't know) whose delay we keep pushing
    /// until the trip arrives, since Träwelling has no timetable of its own to track that.
    var trackedManualCheckins: [TrackedManualCheckin] {
        didSet { Storage.save(trackedManualCheckins, key: "trackedManualCheckins") }
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
        provider = CombinedProvider(vagonweb: VagonwebClient(browserLoader: { url in try await VagonwebBrowser.shared.html(at: url) }))
        traewelling = TraewellingClient(config: TraewellingConfig())
        // Older versions stored everything in UserDefaults; move the raw bytes into files once
        // (re-encoding everything on every launch is what used to slow the start down).
        Storage.migrateFromUserDefaults(keys: ["savedJourneys", "favoriteStations", "recentSearches", "recentStations"])
        favoriteStations = Storage.load(key: "favoriteStations") ?? []
        recentSearches = Storage.load(key: "recentSearches") ?? []
        recentStations = Storage.load(key: "recentStations") ?? []
        savedJourneys = Storage.load(key: "savedJourneys") ?? []
        trackedManualCheckins = Storage.load(key: "trackedManualCheckins") ?? []
        liveJourneys = Storage.load(key: "liveJourneys") ?? LiveDataCache()
        liveTrips = Storage.load(key: "liveTrips") ?? LiveDataCache()
        tickets = TicketStore.load()
        travelPasses = TicketStore.loadPasses()
        manualLiveActivityJourneyID = UserDefaults.standard.string(forKey: "manualLiveActivityJourneyID").flatMap(UUID.init)
        // The check-in history holds every trip's full track geometry and can run to many
        // megabytes, so it's decoded off the main thread instead of blocking the launch.
        traewellingTripsLoadTask = Task { [weak self] in
            let trips = await Task.detached(priority: .userInitiated) { () -> [ImportedTrip] in
                Storage.load(key: "traewellingTrips") ?? []
            }.value
            guard let self else { return }
            traewellingTrips = trips
            traewellingTripsLoaded = true
        }
        // After init, since taking over synced journeys also updates the Live Activity.
        Task { [weak self] in self?.startCloudSync() }
    }

    @ObservationIgnored private var cloudObserver: NSObjectProtocol?
    @ObservationIgnored private let favoriteStationsCloud = CloudList<Station>(key: "favoriteStations")
    @ObservationIgnored private let recentSearchesCloud = CloudList<RecentSearch>(key: "recentSearches")
    @ObservationIgnored private let savedJourneysCloud = CloudList<SavedJourney>(key: "savedJourneys")

    /// Merges with what iCloud already has (uploading what only exists here, e.g. on the first
    /// launch after updating) and takes over changes made on the user's other devices.
    private func startCloudSync() {
        applyCloudChange(keys: ["favoriteStations", "recentSearches", "savedJourneys", AppSettings.cloudKey])
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
        if keys.contains("savedJourneys") {
            savedJourneysCloud.receive(local: savedJourneys) { savedJourneys = $0 }
        }
        if keys.contains(AppSettings.cloudKey) { settings.receiveCloudValue() }
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

    /// Fetches new check-ins and their track geometry. Stops at the first already known status.
    func syncTraewelling(force: Bool = false) async {
        // Without the stored history every check-in would look new and be imported again.
        await loadTraewellingTrips()
        guard settings.traewellingEnabled, settings.syncTraewellingToMap, !isSyncingTraewelling, await traewelling.isLoggedIn else { return }
        if !force, let last = settings.lastTraewellingSync, Date.now.timeIntervalSince(last) < 15 * 60 { return }
        isSyncingTraewelling = true
        defer { isSyncingTraewelling = false }
        do {
            let username = try await traewelling.currentUser().username
            let knownIDs = Set(traewellingTrips.map(\.statusID))
            var newStatuses: [TraewellingStatus] = []
            var page = 1
            pages: while page <= 200 {
                let result = try await traewelling.statuses(username: username, page: page)
                for status in result.statuses {
                    // Everything after a known status was imported before (unless a full resync is forced).
                    if knownIDs.contains(status.id), !force { break pages }
                    if !knownIDs.contains(status.id) { newStatuses.append(status) }
                }
                guard result.hasMore else { break }
                page += 1
                try await Task.sleep(for: .milliseconds(300)) // be gentle with the API
            }

            var imported: [ImportedTrip] = []
            for batch in stride(from: 0, to: newStatuses.count, by: 20).map({ Array(newStatuses[$0..<min($0 + 20, newStatuses.count)]) }) {
                let geometries = (try? await traewelling.polylines(statusIDs: batch.map(\.id))) ?? [:]
                for status in batch {
                    if let journey = status.journey(geometry: geometries[status.id]) {
                        imported.append(ImportedTrip(statusID: status.id, journey: journey))
                    }
                }
            }
            if !imported.isEmpty {
                traewellingTrips = (imported + traewellingTrips).sorted { $0.statusID > $1.statusID }
            }
            settings.lastTraewellingSync = .now
            traewellingSyncError = nil
        } catch {
            traewellingSyncError = error.localizedDescription
        }
    }

    // MARK: Track geometry

    @ObservationIgnored private let geometryService = RouteGeometryService()
    /// Leg ID → encoded polyline, persisted so the map doesn't reload everything.
    /// Loaded off the main thread on first use, since the file can grow large over time.
    @ObservationIgnored private var geometryCacheTask: Task<[String: String], Never>?

    private func loadedGeometryCache() async -> [String: String] {
        if let geometryCacheTask { return await geometryCacheTask.value }
        let task = Task.detached(priority: .utility) { () -> [String: String] in
            Storage.load(key: "legGeometries") ?? [:]
        }
        geometryCacheTask = task
        return await task.value
    }

    func geometry(for leg: Leg) async -> [Coordinate]? {
        var cache = await loadedGeometryCache()
        if let encoded = cache[leg.id] {
            let cached = Polyline.decode(encoded)
            // Earlier versions cached straight lines between the two stations; look those up again
            // instead of drawing them across the map forever.
            if RouteGeometryService.followsTracks(cached) { return cached }
        }
        guard let geometry = await geometryService.geometry(for: leg) else { return nil }
        cache[leg.id] = Polyline.encode(geometry)
        geometryCacheTask = Task { cache }
        Task.detached(priority: .utility) { Storage.save(cache, key: "legGeometries") }
        return geometry
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
        if settings.connectionWarnings { Task { await ConnectionNotifier.requestAuthorization() } }
        savedJourneys.append(SavedJourney(journey: journey, search: search))
        savedJourneys.sort { ($0.journey.departure?.planned ?? .distantPast) < ($1.journey.departure?.planned ?? .distantPast) }
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
    private(set) var trainPositions: [String: LiveTrainPosition] = [:]

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
        guard let bahnDe = provider.bahnDe else { return nil }
        return try await bahnDe.coachSequence(request)
    }

    /// The formation remembered for a saved journey's leg, if any.
    func rememberedFormation(for leg: Leg) -> TrainFormation? {
        let key = leg.formationKey
        return savedJourneys.lazy.compactMap { $0.formations?[key] }.first
    }

    /// Keeps a leg's formation in every saved journey riding it, so its Tz and Taufname stay known
    /// (and sync through iCloud) once the train has run.
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

    // MARK: Manual Träwelling check-ins

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
    private func refresh(_ entry: SavedJourney, using refresher: JourneyRefresher) async {
        let refreshed = await refresher.refresh(entry.journey)
        guard let index = savedJourneys.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = savedJourneys[index]
        let previous = updated.journey
        updated.journey = refreshed
        if settings.connectionWarnings {
            let known = Set(updated.notifiedIssues ?? [])
            let newIssues = refreshed.connectionIssues().filter { !known.contains($0.id) }
            for issue in newIssues {
                await ConnectionNotifier.notify(issue, journey: refreshed)
            }
            // New delay reasons from DB ("Reparatur an einem Signal") get a notification too;
            // plain notices (no WLAN, missing coach) only show as the yellow triangle.
            let newReasons = refreshed.transitLegs.flatMap { leg in
                leg.messages.filter { $0.kind == .delay }.map { (id: "reason|\(leg.id)|\($0.text)", leg: leg, message: $0) }
            }.filter { !known.contains($0.id) }
            for reason in newReasons {
                await ConnectionNotifier.notify(reason.message, leg: reason.leg, id: reason.id)
            }
            // Platform changes for departures and arrivals within the next two hours, incl. transfers.
            let newPlatforms = refreshed.platformChanges(since: previous).filter { !known.contains($0.id) }
            for change in newPlatforms {
                await ConnectionNotifier.notify(change, journey: refreshed)
            }
            updated.notifiedIssues = Array(known.union(newIssues.map(\.id)).union(newReasons.map(\.id))
                .union(newPlatforms.map(\.id)))
        }
        if updated != savedJourneys[index] { savedJourneys[index] = updated }
    }

    /// Past journeys; once their live data is gone (`SavedJourney.liveDataLifetime`) shown as planned,
    /// without any delay.
    var pastJourneys: [SavedJourney] {
        savedJourneys.filter(\.isFinished).reversed().map { entry in
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
        let eligible = liveActivityEligibleJourneys
        if let manualID = manualLiveActivityJourneyID, !upcomingJourneys.contains(where: { $0.id == manualID }) {
            manualLiveActivityJourneyID = nil
            return // the didSet above already re-runs this
        }
        let candidate: SavedJourney?
        if let manualID = manualLiveActivityJourneyID, let manual = eligible.first(where: { $0.id == manualID }) {
            candidate = manual
        } else if let activeID = liveActivities.activeJourneyID, let current = eligible.first(where: { $0.journey.id == activeID }) {
            candidate = current
        } else {
            candidate = eligible.max { $0.savedAt < $1.savedAt }
        }
        // Switched off in the settings: `show(nil)` ends whatever is still running.
        let journey = settings.liveActivitiesEnabled ? candidate?.journey : nil
        Task { await liveActivities.show(journey) }
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
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
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

struct ImportedTrip: Codable, Hashable, Identifiable {
    var id: Int { statusID }
    var statusID: Int
    var journey: Journey
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

    var issues: [ConnectionIssue] { journey.connectionIssues() }

    /// How long after arriving a finished journey is still refreshed when opened.
    static let liveDataLifetime: TimeInterval = 24 * 3600

    /// Finished 10 minutes after the (realtime) arrival.
    var isFinished: Bool {
        (journey.arrival?.best ?? .distantFuture).addingTimeInterval(10 * 60) < .now
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

    static func load<T: Decodable>(key: String) -> T? {
        // Older versions stored everything in UserDefaults.
        let data = (try? Data(contentsOf: file(key))) ?? UserDefaults.standard.data(forKey: key)
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
    /// The ticket those filters check against.
    var ticketType: TicketType {
        didSet {
            UserDefaults.standard.set(ticketType.rawValue, forKey: "ticketType")
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
    var lastTraewellingSync: Date? {
        didSet { UserDefaults.standard.set(lastTraewellingSync, forKey: "lastTraewellingSync") }
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

    /// How often maps refresh the positions of running trains. Stays on this device, since the
    /// data it costs depends on the device's connection.
    var trainPositionRefresh: TrainPositionRefresh {
        didSet { UserDefaults.standard.set(trainPositionRefresh.rawValue, forKey: "trainPositionRefresh") }
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

    /// Träwelling check-ins, login and map import.
    var traewellingEnabled: Bool { expertMode && expertTraewelling }
    /// Editing a journey: changing the exit or re-planning the rest of the route.
    var editJourneyEnabled: Bool { expertMode && expertEditJourney }
    /// Forcing specific trains into a route or swapping a leg for another train.
    var trainChoiceEnabled: Bool { expertMode && expertTrainChoice }

    init() {
        let defaults = UserDefaults.standard
        ticketFilterByDefault = defaults.bool(forKey: "onlyBC100ByDefault")
        ticketType = defaults.string(forKey: "ticketType").flatMap(TicketType.init) ?? .deutschlandticket
        liveActivitiesEnabled = defaults.object(forKey: "liveActivitiesEnabled") as? Bool ?? true
        trainPositionRefresh = defaults.string(forKey: "trainPositionRefresh").flatMap(TrainPositionRefresh.init) ?? .automatic
        expertMode = defaults.bool(forKey: "expertMode")
        expertTraewelling = defaults.bool(forKey: "expertTraewelling")
        expertEditJourney = defaults.bool(forKey: "expertEditJourney")
        expertTrainChoice = defaults.bool(forKey: "expertTrainChoice")
        traewellingVisibility = TraewellingVisibility(rawValue: defaults.integer(forKey: "traewellingVisibility")) ?? .publicVisible
        bc100Rules = Storage.load(key: "bc100Rules") ?? .default
        syncTraewellingToMap = defaults.object(forKey: "syncTraewellingToMap") as? Bool ?? true
        lastTraewellingSync = defaults.object(forKey: "lastTraewellingSync") as? Date
        connectionWarnings = defaults.object(forKey: "connectionWarnings") as? Bool ?? true
        quickTags = Storage.load(key: "quickTags") ?? QuickTag.defaults
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
        expertTrainChoice: false)

    @ObservationIgnored private var isApplyingCloudValue = false

    private var cloudValue: CloudValue {
        CloudValue(ticketFilterByDefault: ticketFilterByDefault, ticketType: ticketType,
                   traewellingVisibility: traewellingVisibility, bc100Rules: bc100Rules,
                   syncTraewellingToMap: syncTraewellingToMap, connectionWarnings: connectionWarnings,
                   quickTags: quickTags, liveActivitiesEnabled: liveActivitiesEnabled, expertMode: expertMode,
                   expertTraewelling: expertTraewelling, expertEditJourney: expertEditJourney,
                   expertTrainChoice: expertTrainChoice)
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

    static func notify(_ message: TrainMessage, leg: Leg, id: String) async {
        let content = UNMutableNotificationContent()
        let line = leg.line?.name ?? "Zug"
        if let delay = leg.departure.delayMinutes, delay > 0 {
            content.title = "\(line): +\(delay) Min."
        } else {
            content.title = "\(line): Verspätungsgrund"
        }
        let since = message.timestamp.map { " (seit \($0.timeString))" } ?? ""
        content.body = message.text + since + "\n\(leg.origin.displayName) → \(leg.destination.displayName)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
