import Foundation

/// A search to the destination and to an alternative one, e.g. another station in the same city (#516): both are
/// searched on their own and their result lists become one.
public enum AlternativeDestination {
    /// The alternative destination to search, nil when there is none or it is the start or the destination itself.
    public static func usable(_ alternative: Station?, from: Station, to: Station) -> Station? {
        guard let alternative, !alternative.isSamePlace(as: to), !alternative.isSamePlace(as: from) else { return nil }
        return alternative
    }

    /// The connections loaded so far to one of the two destinations.
    public struct Results: Sendable {
        public var journeys: [Journey]
        /// More connections can be loaded after the last one.
        public var hasLater: Bool

        public init(journeys: [Journey], hasLater: Bool = false) {
            self.journeys = journeys
            self.hasLater = hasLater
        }

        var lastDeparture: Date? { journeys.compactMap(\.departure?.planned).max() }
    }

    /// The connections to both destinations as one list. Each destination keeps all of its connections, so a train
    /// serving both shows once per destination.
    /// - Sorted by planned departure, then by arrival, fewer changes, and the destination itself first.
    /// - Ends where both lists are known: while one can still load later connections, the other's connections
    ///   leaving after its last one wait for that page, so the end of the list doesn't show only one destination
    ///   and nothing gets sorted in above it later.
    public static func merging(_ main: Results, alternative: Results) -> [Journey] {
        let end = end(main, alternative)
        let all = (main.journeys.map { ($0, true) } + alternative.journeys.map { ($0, false) })
            .filter { journey, _ in end.map { (journey.departure?.planned ?? .distantFuture) <= $0 } ?? true }
        return all.sorted { a, b in
            let left = (a.0.departure?.planned ?? .distantFuture, a.0.arrival?.best ?? .distantFuture, a.0.transfers)
            let right = (b.0.departure?.planned ?? .distantFuture, b.0.arrival?.best ?? .distantFuture, b.0.transfers)
            return left != right ? left < right : a.1 && !b.1
        }
        .map(\.0)
    }

    /// Which of the two lists to page for later connections: one that already reaches past the other's end has
    /// connections waiting there and only pages on once the other has caught up.
    public static func loadsLater(_ main: Results, alternative: Results) -> (main: Bool, alternative: Bool) {
        let end = end(main, alternative)
        func loads(_ results: Results) -> Bool {
            guard results.hasLater else { return false }
            guard let end, let last = results.lastDeparture else { return true }
            return last <= end
        }
        return (loads(main), loads(alternative))
    }

    /// The last departure both lists are known up to, nil when neither can load later connections.
    private static func end(_ main: Results, _ alternative: Results) -> Date? {
        [main, alternative].filter(\.hasLater).compactMap(\.lastDeparture).min()
    }

    /// `merging` without paging, e.g. when both lists are complete.
    public static func merging(_ main: [Journey], alternative: [Journey]) -> [Journey] {
        merging(Results(journeys: main), alternative: Results(journeys: alternative))
    }
}
