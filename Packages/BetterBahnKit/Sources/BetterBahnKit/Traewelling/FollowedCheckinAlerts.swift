import Foundation

/// Which check-ins of the people the user follows get a notification (#266): each one once, and none of
/// those already running when the notifications were turned on (or the app first looked).
public struct FollowedCheckinAlerts: Codable, Sendable, Equatable {
    /// How many status IDs are remembered: far more than the people followed are ever checked in at once.
    static let remembered = 200

    /// The check-ins seen so far, oldest first; `nil` until the first look.
    var known: [Int]?

    public init() {}

    /// The check-ins in `statuses` that weren't there on an earlier look, and remembers them all.
    /// The first look only remembers: what runs already when the notifications start isn't news.
    public mutating func newCheckins(in statuses: [TraewellingStatus]) -> [TraewellingStatus] {
        guard let known else {
            self.known = Array(statuses.map(\.id).suffix(Self.remembered))
            return []
        }
        let seen = Set(known)
        let new = statuses.filter { !seen.contains($0.id) }
        self.known = Array((known + new.map(\.id)).suffix(Self.remembered))
        return new
    }

    /// The notification's text for someone's check-in: who, and the train from where to where.
    public static func title(for status: TraewellingStatus) -> String {
        "\(status.user?.displayName ?? "Jemand") ist eingecheckt"
    }

    public static func body(for status: TraewellingStatus) -> String {
        let checkin = status.checkin
        let origin = checkin.origin.station?.name ?? checkin.origin.name ?? "?"
        let destination = checkin.destination.station?.name ?? checkin.destination.name ?? "?"
        let route = "\(origin) → \(destination)"
        guard let line = checkin.lineName, !line.isEmpty else { return route }
        return "\(line): \(route)"
    }
}
