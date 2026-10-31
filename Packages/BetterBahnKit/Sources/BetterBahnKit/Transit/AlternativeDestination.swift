import Foundation

/// A search to the destination and to an alternative one, e.g. another station in the same city (#516):
/// both result lists become one, in order of departure.
public enum AlternativeDestination {
    /// The alternative destination to search, nil when there is none or it is the start or the destination itself.
    public static func usable(_ alternative: Station?, from: Station, to: Station) -> Station? {
        guard let alternative, !alternative.isSamePlace(as: to), !alternative.isSamePlace(as: from) else { return nil }
        return alternative
    }

    /// The connections to both destinations by planned departure (then arrival). A connection to one
    /// destination is dropped when one to the other rides the same trains up to its last one and arrives
    /// no later: the same train serving both stations, or a change at the first just to get to the second.
    public static func merging(_ main: [Journey], alternative: [Journey]) -> [Journey] {
        // On a tie the connection to the destination itself stays.
        let keptAlternative = alternative.filter { journey in !main.contains { $0.covers(journey) } }
        let keptMain = main.filter { journey in !keptAlternative.contains { $0.covers(journey) } }
        let all = keptMain + keptAlternative
        return all.enumerated().sorted { a, b in
            let left = (a.element.departure?.planned ?? .distantFuture, a.element.arrival?.planned ?? .distantFuture)
            let right = (b.element.departure?.planned ?? .distantFuture, b.element.arrival?.planned ?? .distantFuture)
            return left != right ? left < right : a.offset < b.offset
        }
        .map(\.element)
    }
}

extension Journey {
    /// Rides the same trains as `other` from its start, gets off its last one no later than `other`
    /// arrives, and so makes `other` pointless when either destination will do.
    func covers(_ other: Journey) -> Bool {
        let legs = transitLegs, otherLegs = other.transitLegs
        guard !legs.isEmpty, legs.count <= otherLegs.count,
              let arrival = arrival?.best, let otherArrival = other.arrival?.best, arrival <= otherArrival
        else { return false }
        for (index, leg) in legs.enumerated() {
            let otherLeg = otherLegs[index]
            guard leg.isSameTrain(as: otherLeg) else { return false }
            // Before the last train, the changes have to be the same too.
            if index < legs.count - 1,
               !(leg.destination.isSamePlace(as: otherLeg.destination) && leg.arrival.planned == otherLeg.arrival.planned) {
                return false
            }
        }
        return true
    }
}

extension Leg {
    /// The same train boarded at the same place and time; only where each gets off may differ.
    func isSameTrain(as other: Leg) -> Bool {
        guard departure.planned == other.departure.planned, origin.isSamePlace(as: other.origin) else { return false }
        if let tripId, tripId == other.tripId { return true }
        guard let number = line?.number ?? line?.name, number == (other.line?.number ?? other.line?.name) else { return false }
        return true
    }
}
