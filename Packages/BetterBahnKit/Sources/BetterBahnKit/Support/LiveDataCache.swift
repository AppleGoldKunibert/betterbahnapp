import Foundation

/// The latest live version of journeys or train runs already seen, by ID, so opening one again shows
/// it right away (and refreshes in the background) instead of waiting for live data behind a spinner.
/// Codable so the app can keep it on disk across restarts. Entries older than `maxAge` count as
/// unseen, and only the `limit` most recent are kept.
public struct LiveDataCache<Value: Codable & Sendable>: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var value: Value
        var date: Date
    }

    public static var maxAge: TimeInterval { 12 * 3600 }
    public static var limit: Int { 50 }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func value(for id: String, now: Date = .now) -> Value? {
        guard let entry = entries[id], now.timeIntervalSince(entry.date) < Self.maxAge else { return nil }
        return entry.value
    }

    public mutating func store(_ value: Value, for id: String, now: Date = .now) {
        entries[id] = Entry(value: value, date: now)
        entries = entries.filter { now.timeIntervalSince($0.value.date) < Self.maxAge }
        if entries.count > Self.limit {
            let newest = entries.sorted { $0.value.date > $1.value.date }.prefix(Self.limit)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }
}
