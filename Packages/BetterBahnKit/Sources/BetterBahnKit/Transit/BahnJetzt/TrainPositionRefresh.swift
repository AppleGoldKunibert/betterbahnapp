import Foundation

/// How often the live positions of running trains are fetched from bahn.jetzt while a map shows them.
/// Each fetch downloads bahn.jetzt's full list of every running train (~250 KB), so shorter intervals
/// use noticeably more data.
public enum TrainPositionRefresh: String, CaseIterable, Codable, Sendable {
    /// Every 15 seconds, or every minute on mobile data or in Low Data Mode.
    case automatic
    case every15Seconds
    case every30Seconds
    case everyMinute
    case every2Minutes
    /// Positions are fetched once when a map opens and then not refreshed.
    case off

    /// The automatic interval on Wi-Fi.
    public static let automaticInterval: Duration = .seconds(15)
    /// The automatic interval on mobile data or in Low Data Mode.
    public static let automaticIntervalSavingData: Duration = .seconds(60)

    /// The pause between two fetches; nil when positions aren't refreshed at all.
    /// - Parameter savingData: whether the device is on mobile data or in Low Data Mode.
    public func interval(savingData: Bool) -> Duration? {
        switch self {
        case .automatic: savingData ? Self.automaticIntervalSavingData : Self.automaticInterval
        case .every15Seconds: .seconds(15)
        case .every30Seconds: .seconds(30)
        case .everyMinute: .seconds(60)
        case .every2Minutes: .seconds(120)
        case .off: nil
        }
    }

    public var displayName: String {
        switch self {
        case .automatic: "Automatisch"
        case .every15Seconds: "15 Sek."
        case .every30Seconds: "30 Sek."
        case .everyMinute: "1 Min."
        case .every2Minutes: "2 Min."
        case .off: "Aus"
        }
    }
}
