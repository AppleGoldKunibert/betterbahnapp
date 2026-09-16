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

    init() {
        provider = Self.makeProvider(settings: settings)
        traewelling = TraewellingClient(config: TraewellingConfig(clientID: settings.traewellingClientID))
        favoriteStations = Storage.load(key: "favoriteStations") ?? []
        recentSearches = Storage.load(key: "recentSearches") ?? []
        recentStations = Storage.load(key: "recentStations") ?? []
        savedJourneys = Storage.load(key: "savedJourneys") ?? []
        traewellingTrips = Storage.load(key: "traewellingTrips") ?? []
        // Move data from UserDefaults (older versions) into files.
        Storage.save(savedJourneys, key: "savedJourneys")
        Storage.save(favoriteStations, key: "favoriteStations")
        Storage.save(recentSearches, key: "recentSearches")
        Storage.save(recentStations, key: "recentStations")
    }

    var trainPicker: TrainPicker { TrainPicker(provider: provider) }

    var bc100Rules: BC100Rules { settings.bc100Rules }

    /// Rebuilds clients after settings like the db-rest URL or client ID changed.
    func applySettings() {
        provider = Self.makeProvider(settings: settings)
        traewelling = TraewellingClient(config: TraewellingConfig(clientID: settings.traewellingClientID))
    }

    private static func makeProvider(settings: AppSettings) -> CombinedProvider {
        let url = URL(string: settings.dbRestBaseURL) ?? DBRestProvider.defaultBaseURL
        return CombinedProvider(primary: DBRestProvider(baseURL: url))
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
    @ObservationIgnored private lazy var geometryCache: [String: String] = {
        let cache: [String: String] = Storage.load(key: "legGeometries") ?? [:]
        Storage.save(cache, key: "legGeometries")
        return cache
    }()

    func geometry(for leg: Leg) async -> [Coordinate]? {
        if let cached = geometryCache[leg.id] { return Polyline.decode(cached) }
        guard let geometry = await geometryService.geometry(for: leg) else { return nil }
        geometryCache[leg.id] = Polyline.encode(geometry)
        Storage.save(geometryCache, key: "legGeometries")
        return geometry
    }

    // MARK: Saved journeys

    func isSaved(_ journey: Journey) -> Bool {
        savedJourneys.contains { $0.journey.id == journey.id }
    }

    func save(_ journey: Journey) {
        guard !isSaved(journey) else { return }
        if settings.connectionWarnings { Task { await ConnectionNotifier.requestAuthorization() } }
        savedJourneys.append(SavedJourney(journey: journey))
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

    /// Replaces a saved journey with an alternative and keeps the old plan.
    func replaceSaved(id: UUID, with journey: Journey, reason: String) {
        guard let index = savedJourneys.firstIndex(where: { $0.id == id }) else { return }
        var entry = savedJourneys[index]
        let old = PlanVersion(journey: entry.journey, replacedAt: .now, reason: reason)
        entry.previousVersions = [old] + (entry.previousVersions ?? [])
        entry.journey = journey
        entry.notifiedIssues = []
        savedJourneys[index] = entry
    }

    // MARK: Realtime refresh & warnings

    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    /// Refreshes upcoming journeys every 2 minutes while the app is active.
    func startRefreshing() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSavedJourneys()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func stopRefreshing() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    /// Updates realtime data of journeys in the next 24 hours and warns about broken connections.
    func refreshSavedJourneys() async {
        let refresher = JourneyRefresher(provider: provider)
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

    /// Shows the Live Activity for the next saved journey that hasn't ended yet.
    func syncLiveActivity() {
        let next = upcomingJourneys.first?.journey
        Task { await liveActivities.show(next) }
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

struct RecentSearch: Codable, Hashable, Identifiable {
    var id: String { from.id + "→" + to.id }
    var from: Station
    var to: Station
}

/// JSON files in Application Support (saved journeys and route shapes get large).
enum Storage {
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
    var dbRestBaseURL: String {
        didSet { UserDefaults.standard.set(dbRestBaseURL, forKey: "dbRestBaseURL") }
    }
    var onlyBC100ByDefault: Bool {
        didSet { UserDefaults.standard.set(onlyBC100ByDefault, forKey: "onlyBC100ByDefault") }
    }
    var traewellingClientID: String {
        didSet { UserDefaults.standard.set(traewellingClientID, forKey: "traewellingClientID") }
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

    init() {
        let defaults = UserDefaults.standard
        dbRestBaseURL = defaults.string(forKey: "dbRestBaseURL") ?? DBRestProvider.defaultBaseURL.absoluteString
        onlyBC100ByDefault = defaults.bool(forKey: "onlyBC100ByDefault")
        traewellingClientID = defaults.string(forKey: "traewellingClientID") ?? ""
        traewellingVisibility = TraewellingVisibility(rawValue: defaults.integer(forKey: "traewellingVisibility")) ?? .publicVisible
        bc100Rules = Storage.load(key: "bc100Rules") ?? .default
        syncTraewellingToMap = defaults.object(forKey: "syncTraewellingToMap") as? Bool ?? true
        lastTraewellingSync = defaults.object(forKey: "lastTraewellingSync") as? Date
        connectionWarnings = defaults.object(forKey: "connectionWarnings") as? Bool ?? true
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
        let route = [journey.legs.first?.origin.name, journey.legs.last?.destination.name].compactMap { $0 }.joined(separator: " → ")
        content.body = issue.message + (route.isEmpty ? "" : "\n\(route)")
        content.sound = issue.isBlocking ? .defaultCritical : .default
        content.interruptionLevel = issue.isBlocking ? .timeSensitive : .active
        let request = UNNotificationRequest(identifier: issue.id + journey.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
