import Foundation
import Synchronization

/// What bahn.de called trains Transitous names otherwise, remembered on the device: DB's feed has the ČD
/// Railjet "RJ 176" Berlin–Hamburg as "ICE 176". Journeys wait only 3 s for bahn.de's name, so when our
/// server answered slowly the result showed "ICE 176" where a search a minute later showed "RJ 176". A name
/// bahn.de gave once is used right away from then on, until bahn.de says otherwise or it is `maxAge` old.
public final class TrainNameMemory: Sendable {
    public static let shared = TrainNameMemory()

    /// Long enough to carry over from one trip to the next, short enough to forget a timetable change.
    static let maxAge: TimeInterval = 42 * 24 * 3600
    static let limit = 500
    static let key = "bahnDeTrainNames"

    struct Entry: Codable {
        var name: String
        var learned: Date
    }

    /// Where the names are kept (the standard defaults when nil); a name, since `UserDefaults` isn't `Sendable`.
    private let defaultsSuite: String?
    private let entries: Mutex<[String: Entry]>

    private var defaults: UserDefaults { defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public init(defaultsSuite: String? = nil) {
        self.defaultsSuite = defaultsSuite
        let defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) }
        entries = Mutex(stored ?? [:])
    }

    /// bahn.de's name for the train Transitous calls `name`, if it gave a different one within `maxAge`.
    public func name(for name: String, now: Date = .now) -> String? {
        let key = BahnDeClient.normalizedTrainName(name)
        return entries.withLock { entries in
            guard let entry = entries[key], now.timeIntervalSince(entry.learned) < Self.maxAge else { return nil }
            return entry.name
        }
    }

    /// Remembers that bahn.de calls the train Transitous calls `original` `name`; forgets it when the two are alike.
    public func remember(_ name: String, for original: String, now: Date = .now) {
        let key = BahnDeClient.normalizedTrainName(original)
        let snapshot: [String: Entry]? = entries.withLock { entries in
            if key == BahnDeClient.normalizedTrainName(name) {
                guard entries.removeValue(forKey: key) != nil else { return nil }
            } else {
                // Written at most once a day per train: every search asks again.
                if let entry = entries[key], entry.name == name, now.timeIntervalSince(entry.learned) < 24 * 3600 { return nil }
                entries[key] = Entry(name: name, learned: now)
                if entries.count > Self.limit {
                    entries = entries.filter { now.timeIntervalSince($0.value.learned) < Self.maxAge }
                    while entries.count > Self.limit, let oldest = entries.min(by: { $0.value.learned < $1.value.learned }) {
                        entries.removeValue(forKey: oldest.key)
                    }
                }
            }
            return entries
        }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
