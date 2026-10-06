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
/// extension. Both find the group's ID under `appGroupInfoKey` in their Info.plist (it follows the
/// bundle ID, so a build with `LOCAL_BUNDLE_ID_SUFFIX` gets its own group).
public enum WidgetStore {
    public static let appGroupInfoKey = "BetterBahnAppGroup"
    static let fileName = "widgetSnapshot.json"

    /// Widget kinds, for reloading their timelines from the app.
    public static let journeyWidgetKind = "JourneyOverviewWidget"

    public static var fileURL: URL? {
        #if os(iOS) || os(macOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent(fileName)
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
