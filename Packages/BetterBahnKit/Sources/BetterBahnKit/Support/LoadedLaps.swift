import Foundation

/// The laps of a looping train (Ringbahn) the user loaded around the one a trip opened on ("Vorherige /
/// Nächste Runde laden", `Trip.lap`), so opening the same trip again shows them again. Forgotten once
/// nobody looked at that trip for `keepFor`, unless the trip is saved. Codable so the app can keep it on
/// disk across restarts.
public struct LoadedLaps: Codable, Sendable {
    public struct Extra: Codable, Sendable, Hashable {
        public var before = 0
        public var after = 0
        public init(before: Int = 0, after: Int = 0) {
            self.before = before
            self.after = after
        }
    }

    struct Entry: Codable, Sendable {
        var tripId: String
        var extra: Extra
        var viewed: Date
    }

    /// How long an unsaved trip's loaded laps stay after it was last looked at.
    public static var keepFor: TimeInterval { 15 * 60 }
    public static var limit: Int { 50 }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// The same trip opened from another stop or time has laps of its own.
    public static func key(tripId: String, station: Station, near time: Date) -> String {
        "\(tripId)|\(station.id)|\(Int(time.timeIntervalSince1970))"
    }

    /// The laps to show when `key` is opened: the remembered ones unless they expired. Opening counts as
    /// looking at it.
    public mutating func open(_ key: String, isSaved: Bool, now: Date = .now) -> Extra {
        guard let entry = entries[key] else { return Extra() }
        if !isSaved, now.timeIntervalSince(entry.viewed) >= Self.keepFor {
            entries[key] = nil
            return Extra()
        }
        entries[key]?.viewed = now
        return entry.extra
    }

    /// Remembers `extra` for `key` (a trip `tripId`), and drops what expired meanwhile: `isSaved` says
    /// for a trip ID whether its laps stay anyway.
    public mutating func store(_ extra: Extra, for key: String, tripId: String, now: Date = .now,
                               isSaved: (String) -> Bool) {
        if extra == Extra() {
            entries[key] = nil
        } else {
            entries[key] = Entry(tripId: tripId, extra: extra, viewed: now)
        }
        entries = entries.filter { isSaved($0.value.tripId) || now.timeIntervalSince($0.value.viewed) < Self.keepFor }
        if entries.count > Self.limit {
            let newest = entries.sorted { $0.value.viewed > $1.value.viewed }.prefix(Self.limit)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }

    /// The trip was looked at (or closed) just now, so its laps stay another `keepFor`.
    public mutating func viewed(_ key: String, now: Date = .now) {
        entries[key]?.viewed = now
    }
}
