import Foundation

/// What the app hands the home-screen widgets through the shared App Group container: the journey
/// the widgets follow (the one the Live Activity shows, else the next saved one) and the latest
/// positions of its trains. Widgets can't run the app's refresh loops, so they show this data as of
/// `updatedAt` and work out the rest (countdowns, next stop) from the timetable.
public struct WidgetSnapshot: Codable, Sendable, Hashable {
    /// The journey's ID, also used for `LiveActivityLink` when a widget is tapped.
    public var journeyID: String?
    public var journey: Journey?
    /// Latest known position per train, keyed by `Line.name` (from bahn.jetzt).
    public var trainPositions: [String: TrainPosition]
    /// When the app last wrote this, shown as "Stand hh:mm".
    public var updatedAt: Date

    public init(journey: Journey?, trainPositions: [String: TrainPosition] = [:], updatedAt: Date = .now) {
        self.journeyID = journey?.id
        self.journey = journey
        self.trainPositions = trainPositions
        self.updatedAt = updatedAt
    }

    /// Same journey and positions, whenever it was written: nothing a widget would show differently.
    public func hasSameContent(as other: WidgetSnapshot?) -> Bool {
        guard let other else { return false }
        return journey == other.journey && trainPositions == other.trainPositions
    }
}

/// Reads and writes the `WidgetSnapshot` in the App Group container shared by the app and the widget
/// extension. Both find the group's ID under `appGroupInfoKey` in their Info.plist. It is written out
/// in full there and in the entitlements: Xcode's automatic signing doesn't resolve build settings in
/// App Group names and fails to register "group.…$(LOCAL_BUNDLE_ID_SUFFIX)".
public enum WidgetStore {
    public static let appGroupInfoKey = "BetterBahnAppGroup"
    static let fileName = "widgetSnapshot.json"

    /// Widget kinds, for reloading their timelines from the app.
    public static let journeyWidgetKind = "JourneyOverviewWidget"
    public static let currentTrainWidgetKind = "CurrentTrainWidget"
    public static let liveSpeedWidgetKind = "LiveSpeedWidget"
    public static let livePositionWidgetKind = "LivePositionWidget"
    public static let boardWidgetKind = "StationBoardWidget"
    /// The widgets that follow the snapshot's journey: the ones the app reloads when it changes (the
    /// board widget fetches on its own and isn't reloaded for that).
    public static let journeyWidgetKinds = [journeyWidgetKind, currentTrainWidgetKind, liveSpeedWidgetKind, livePositionWidgetKind]

    public static var fileURL: URL? { containerURL?.appendingPathComponent(fileName) }
    public static var stationsFileURL: URL? { containerURL?.appendingPathComponent(WidgetStations.fileName) }

    private static var containerURL: URL? {
        #if os(iOS) || os(macOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        #else
        return nil
        #endif
    }

    public static func load(from url: URL? = fileURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public static func save(_ snapshot: WidgetSnapshot, to url: URL? = fileURL) {
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The stations the departure board widget can be set to (#314): the favourites and the routes searched
/// last, written by the app to the App Group container whenever they change. The widget's settings
/// list them; the station is always picked by the user, never found by location.
public struct WidgetStations: Codable, Sendable, Hashable {
    static let fileName = "widgetStations.json"

    public struct Route: Codable, Sendable, Hashable {
        public var from: Station
        public var to: Station

        public init(from: Station, to: Station) {
            self.from = from
            self.to = to
        }
    }

    public var favorites: [Station]
    public var recentRoutes: [Route]

    public init(favorites: [Station], recentRoutes: [Route]) {
        self.favorites = favorites
        self.recentRoutes = recentRoutes
    }

    /// Stations to pick a route's destination from: the favourites, then every end of a recent route,
    /// each place once.
    public var destinations: [Station] {
        var result: [Station] = []
        for station in favorites + recentRoutes.flatMap({ [$0.to, $0.from] }) where !result.contains(where: { $0.isSamePlace(as: station) }) {
            result.append(station)
        }
        return result
    }

    public static func load(from url: URL? = WidgetStore.stationsFileURL) -> WidgetStations? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetStations.self, from: data)
    }

    public static func save(_ stations: WidgetStations, to url: URL? = WidgetStore.stationsFileURL) {
        guard let url, let data = try? JSONEncoder().encode(stations) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
