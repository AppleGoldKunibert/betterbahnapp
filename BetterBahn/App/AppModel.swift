import BackgroundTasks
import BetterBahnKit
import Foundation
import Observation
import UserNotifications

@Observable
final class AppModel {
    let settings = AppSettings()
    private(set) var provider: CombinedProvider
    private(set) var traewelling: TraewellingClient
    let liveActivities = LiveActivityManager()
    @ObservationIgnored private let timetablesStore = TimetablesCredentialsStore()
    private(set) var timetablesCredentials: TimetablesCredentials?

    var favoriteStations: [Station] {
        didSet { Storage.save(favoriteStations, key: "favoriteStations") }
    }
    var recentSearches: [RecentSearch] {
        didSet { Storage.save(recentSearches, key: "recentSearches") }
    }
    /// Journeys the user saved. The next upcoming one is shown as Live Activity.
    var savedJourneys: [SavedJourney] {
        didSet {
            Storage.save(savedJourneys, key: "savedJourneys")
            syncLiveActivity()
        }
    }
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
        provider = CombinedProvider()
        traewelling = TraewellingClient(config: TraewellingConfig())
        timetablesCredentials = timetablesStore.load()
        favoriteStations = Storage.load(key: "favoriteStations") ?? []
        recentSearches = Storage.load(key: "recentSearches") ?? []
        recentStations = Storage.load(key: "recentStations") ?? []
        savedJourneys = Storage.load(key: "savedJourneys") ?? []
        traewellingTrips = Storage.load(key: "traewellingTrips") ?? []
        trackedManualCheckins = Storage.load(key: "trackedManualCheckins") ?? []
        manualLiveActivityJourneyID = UserDefaults.standard.string(forKey: "manualLiveActivityJourneyID").flatMap(UUID.init)
        // Move data from UserDefaults (older versions) into files.
        Storage.save(savedJourneys, key: "savedJourneys")
        Storage.save(favoriteStations, key: "favoriteStations")
        Storage.save(recentSearches, key: "recentSearches")
        Storage.save(recentStations, key: "recentStations")
    }

    var trainPicker: TrainPicker { TrainPicker(provider: provider) }

    var journeyReplanner: JourneyReplanner { JourneyReplanner(provider: provider) }

    var trainRoutePlanner: TrainRoutePlanner { TrainRoutePlanner(provider: provider, timetables: timetablesClient) }

    var bc100Rules: BC100Rules { settings.bc100Rules }

    /// Overlays fresher delay/platform data straight from DB onto legs. Uses the user's own
    /// credentials from Einstellungen → Erweiterte Einstellungen when set, otherwise the key
    /// BetterBahn ships with (`TimetablesCredentials.shipped`); `nil` when neither is configured.
    var timetablesClient: TimetablesClient? {
        let credentials = timetablesCredentials ?? .shipped
        guard credentials.isConfigured else { return nil }
        return TimetablesClient(credentials: credentials)
    }

    var journeyRefresher: JourneyRefresher { JourneyRefresher(provider: provider, timetables: timetablesClient) }

    /// Saves (or, when both fields are empty, clears back to the shipped default) the DB Timetables
    /// API credentials.
    func updateTimetablesCredentials(clientID: String, apiKey: String) {
        let trimmedID = clientID.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedID.isEmpty || !trimmedKey.isEmpty else {
            timetablesStore.clear()
            timetablesCredentials = nil
            return
        }
        let credentials = TimetablesCredentials(clientID: trimmedID, apiKey: trimmedKey)
        timetablesStore.save(credentials)
        timetablesCredentials = credentials
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

    /// Check-ins imported from Träwelling (newest first), shown on the travel map.
    var traewellingTrips: [ImportedTrip] {
        didSet { Storage.save(traewellingTrips, key: "traewellingTrips") }
    }
    private(set) var isSyncingTraewelling = false
    private(set) var traewellingSyncError: String?

    /// Fetches new check-ins and their track geometry. Stops at the first already known status.
    func syncTraewelling(force: Bool = false) async {
        guard settings.syncTraewellingToMap, !isSyncingTraewelling, await traewelling.isLoggedIn else { return }
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
        savedJourneys.removeAll { $0.journey.id == journey.id }
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

    /// How often the position of running ICEs of saved journeys is fetched.
    static let positionRefreshInterval: Duration = .seconds(45)

    /// Latest GPS fix of every ICE on a saved journey that is running right now, keyed by train name.
    private(set) var trainPositions: [String: LiveTrainPosition] = [:]

    @ObservationIgnored private var positionLoop: Task<Void, Never>?
    @ObservationIgnored private var familyCache: [String: String?] = [:]

    /// Fetches the position of each ICE leg of an unfinished saved journey that is underway
    /// (plus 10 minutes either side, since departures and arrivals shift).
    func refreshTrainPositions() async {
        guard let bahnExpert = provider.bahnExpert else { return }
        let now = Date.now
        let legs = upcomingJourneys.flatMap(\.journey.transitLegs).filter { leg in
            BahnExpertClient.trainReference(for: leg.line)?.category == "ICE" && !leg.cancelled
                && leg.departure.best.addingTimeInterval(-600) <= now && now <= leg.arrival.best.addingTimeInterval(600)
        }
        var found: [String: LiveTrainPosition] = [:]
        await withTaskGroup(of: LiveTrainPosition?.self) { group in
            for leg in legs {
                group.addTask {
                    guard let name = leg.line?.name, let position = try? await bahnExpert.position(for: leg) else { return nil }
                    return LiveTrainPosition(trainName: name, position: position)
                }
            }
            for await live in group {
                if let live { found[live.trainName] = live }
            }
        }
        trainPositions = found
    }

    /// "ICE 4", "ICE 3neo", "ICE L" … for an ICE, from bahn.expert. Cached per train and day;
    /// failed requests are not cached so they are retried.
    func trainFamily(for line: Line?, on date: Date) async -> String? {
        guard let ref = BahnExpertClient.trainReference(for: line), ref.category == "ICE",
              let bahnExpert = provider.bahnExpert else { return nil }
        let day = BahnExpertClient.berlinDay(date)
        let key = "\(ref.category) \(ref.number)|\(day)"
        if let cached = familyCache[key] { return cached }
        guard let lookup = try? await bahnExpert.trainType(category: ref.category, number: ref.number, date: day) else { return nil }
        let family = lookup.summary
        familyCache[key] = .some(family)
        return family
    }

    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var liveActivitySyncLoop: Task<Void, Never>?

    /// Refreshes upcoming journeys and manual Träwelling check-ins every 5 minutes while the app is active.
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
        if positionLoop == nil {
            positionLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshTrainPositions()
                    try? await Task.sleep(for: Self.positionRefreshInterval)
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
        positionLoop?.cancel()
        positionLoop = nil
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
            let refreshed = await refresher.refresh(entry.journey)
            guard let index = savedJourneys.firstIndex(where: { $0.id == entry.id }) else { continue }
            var updated = savedJourneys[index]
            updated.journey = refreshed
            if settings.connectionWarnings {
                let known = Set(updated.notifiedIssues ?? [])
                let newIssues = refreshed.connectionIssues().filter { !known.contains($0.id) }
                for issue in newIssues {
                    await ConnectionNotifier.notify(issue, journey: refreshed)
                }
                updated.notifiedIssues = Array(known.union(newIssues.map(\.id)))
            }
            if updated != savedJourneys[index] { savedJourneys[index] = updated }
        }
    }


    var pastJourneys: [SavedJourney] {
        savedJourneys.filter(\.isFinished).reversed()
    }

    /// Upcoming journeys within their Live Activity window: from 30 minutes before departure until
    /// they finish. Only one of these is ever shown at a time (see `syncLiveActivity`).
    var liveActivityEligibleJourneys: [SavedJourney] {
        let now = Date.now
        return upcomingJourneys.filter { !dismissedLiveActivityJourneyIDs.contains($0.id) && ($0.journey.departure?.best ?? .distantFuture).addingTimeInterval(-30 * 60) <= now }
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
        let journey = candidate?.journey
        Task { await liveActivities.show(journey) }
    }

    /// Identifier for the background refresh task that ends the Live Activity once its journey
    /// finishes while the app is backgrounded (see `scheduleLiveActivityBackgroundCheck`). Must
    /// match an entry in `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let liveActivityBackgroundTaskID = "de.goldkunibert.BetterBahn.endLiveActivity"

    /// Schedules a background wake-up for shortly after the currently live journey is expected to
    /// finish, since `liveActivitySyncLoop` (which normally detects that) only runs in the
    /// foreground. No-op if no journey is currently live. Called when the app backgrounds.
    func scheduleLiveActivityBackgroundCheck() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.liveActivityBackgroundTaskID)
        guard let activeID = liveActivities.activeJourneyID,
              let entry = savedJourneys.first(where: { $0.journey.id == activeID }),
              let arrival = entry.journey.arrival?.best else { return }
        // Matches the 10-minute grace period in `SavedJourney.isFinished`, plus a small buffer so
        // the eligibility check has already flipped by the time the task runs.
        let fireDate = arrival.addingTimeInterval(10 * 60 + 30)
        guard fireDate > .now else { return }
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
            await refreshSavedJourneys()
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
struct PlanVersion: Codable, Hashable, Identifiable {
    var id = UUID()
    var journey: Journey
    var replacedAt: Date
    var reason: String
}

struct SavedJourney: Codable, Hashable, Identifiable {
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

    var issues: [ConnectionIssue] { journey.connectionIssues() }

    /// Finished 10 minutes after the (realtime) arrival.
    var isFinished: Bool {
        (journey.arrival?.best ?? .distantFuture).addingTimeInterval(10 * 60) < .now
    }
}

/// Where a saved journey's ICE is right now.
struct LiveTrainPosition: Identifiable, Hashable, Sendable {
    var id: String { trainName }
    let trainName: String
    let position: TrainPosition
}

struct RecentSearch: Codable, Hashable, Identifiable {
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

    static func load<T: Decodable>(key: String) -> T? {
        // Older versions stored everything in UserDefaults.
        let data = (try? Data(contentsOf: file(key))) ?? UserDefaults.standard.data(forKey: key)
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

@Observable
final class AppSettings {
    var onlyBC100ByDefault: Bool {
        didSet { UserDefaults.standard.set(onlyBC100ByDefault, forKey: "onlyBC100ByDefault") }
    }
    var traewellingVisibility: TraewellingVisibility {
        didSet { UserDefaults.standard.set(traewellingVisibility.rawValue, forKey: "traewellingVisibility") }
    }
    var bc100Rules: BC100Rules {
        didSet { Storage.save(bc100Rules, key: "bc100Rules") }
    }
    var syncTraewellingToMap: Bool {
        didSet { UserDefaults.standard.set(syncTraewellingToMap, forKey: "syncTraewellingToMap") }
    }
    var connectionWarnings: Bool {
        didSet { UserDefaults.standard.set(connectionWarnings, forKey: "connectionWarnings") }
    }
    var lastTraewellingSync: Date? {
        didSet { UserDefaults.standard.set(lastTraewellingSync, forKey: "lastTraewellingSync") }
    }
    /// Suggested tags offered as quick-add chips in the Träwelling check-in sheet.
    var quickTags: [QuickTag] {
        didSet { Storage.save(quickTags, key: "quickTags") }
    }

    init() {
        let defaults = UserDefaults.standard
        onlyBC100ByDefault = defaults.bool(forKey: "onlyBC100ByDefault")
        traewellingVisibility = TraewellingVisibility(rawValue: defaults.integer(forKey: "traewellingVisibility")) ?? .publicVisible
        bc100Rules = Storage.load(key: "bc100Rules") ?? .default
        syncTraewellingToMap = defaults.object(forKey: "syncTraewellingToMap") as? Bool ?? true
        lastTraewellingSync = defaults.object(forKey: "lastTraewellingSync") as? Date
        connectionWarnings = defaults.object(forKey: "connectionWarnings") as? Bool ?? true
        quickTags = Storage.load(key: "quickTags") ?? QuickTag.defaults
    }
}

/// Local notifications for broken connections.
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
}
