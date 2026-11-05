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

    /// The connections to both destinations as one list, as either destination will do:
    /// - A connection is dropped when one to the other destination leaves no earlier, arrives no later, changes no
    ///   more often and needs no long-distance train it doesn't (e.g. the same ICE calling at both stations, or a
    ///   change at the first just to get to the second). On a full tie the one to the destination itself stays.
    /// - Sorted by planned departure, then by arrival, fewer changes, and the destination itself first.
    /// - Ends where both lists are known: while one can still load later connections, the other's connections
    ///   leaving after its last one wait for that page, so the list neither changes order there nor shows a
    ///   connection the next page would drop.
    public static func merging(_ main: Results, alternative: Results) -> [Journey] {
        let keptAlternative = alternative.journeys.filter { journey in !main.journeys.contains { $0.dominates(journey) } }
        let keptMain = main.journeys.filter { journey in !keptAlternative.contains { $0.dominates(journey) } }
        let end = end(main, alternative)
        let all = (keptMain.map { ($0, true) } + keptAlternative.map { ($0, false) })
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

extension Journey {
    /// At least as good as `other` when either destination will do: leaves no earlier, arrives no later (both with
    /// live times), changes no more often and needs no long-distance train `other` doesn't. A cancelled
    /// connection or one with a missed change is no replacement.
    func dominates(_ other: Journey) -> Bool {
        guard !transitLegs.isEmpty, !isCancelled, brokenTransferIndices.isEmpty,
              let departure = departure?.best, let arrival = arrival?.best,
              let otherDeparture = other.departure?.best, let otherArrival = other.arrival?.best,
              departure >= otherDeparture, arrival <= otherArrival, transfers <= other.transfers
        else { return false }
        return !usesLongDistance || other.usesLongDistance
    }

    var usesLongDistance: Bool { transitLegs.contains { $0.line?.product.isLongDistance == true } }
}
