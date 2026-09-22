import Foundation

/// Problems with a (saved) journey based on realtime data.
public enum ConnectionIssue: Sendable, Hashable, Identifiable {
    /// The next train leaves before (or too shortly after) the previous one arrives.
    case transferMissed(at: String, arrivingLine: String, departingLine: String, bufferMinutes: Int)
    /// Transfer is tight but still possible.
    case transferAtRisk(at: String, arrivingLine: String, departingLine: String, bufferMinutes: Int)
    case legCancelled(line: String, from: String, to: String)

    public var id: String {
        switch self {
        case .transferMissed(let at, let a, let d, _): "missed|\(at)|\(a)|\(d)"
        case .transferAtRisk(let at, let a, let d, _): "risk|\(at)|\(a)|\(d)"
        case .legCancelled(let line, let from, let to): "cancelled|\(line)|\(from)|\(to)"
        }
    }

    public var isBlocking: Bool {
        if case .transferAtRisk = self { return false }
        return true
    }

    public var title: String {
        switch self {
        case .transferMissed(let at, _, _, _): "Umstieg in \(at) klappt nicht mehr"
        case .transferAtRisk(let at, _, _, _): "Umstieg in \(at) wird knapp"
        case .legCancelled(let line, _, _): "\(line) fällt aus"
        }
    }

    public var message: String {
        switch self {
        case .transferMissed(_, let arriving, let departing, let buffer):
            buffer < 0
                ? "\(departing) fährt \(-buffer) Min. bevor \(arriving) ankommt."
                : "Nur \(buffer) Min. zum Umsteigen von \(arriving) in \(departing)."
        case .transferAtRisk(_, let arriving, let departing, let buffer):
            "\(buffer) Min. zum Umsteigen von \(arriving) in \(departing)."
        case .legCancelled(_, let from, let to):
            "Die Fahrt von \(from) nach \(to) findet nicht statt."
        }
    }
}

public extension Journey {
    /// Transfers under `minimumTransfer` minutes (based on realtime data) count as missed, under
    /// `riskTransfer` as at risk. Any walking time between the legs is shown separately in the UI and
    /// doesn't factor into these thresholds, since a planned transfer already accounts for it.
    func connectionIssues(minimumTransfer: Int = 1, riskTransfer: Int = 5) -> [ConnectionIssue] {
        var issues: [ConnectionIssue] = []
        let transit = transitLegs
        for leg in transit where leg.cancelled {
            issues.append(.legCancelled(line: leg.line?.name ?? "Zug", from: leg.origin.name, to: leg.destination.name))
        }
        guard transit.count > 1 else { return issues }
        for index in 1..<transit.count {
            let arriving = transit[index - 1], departing = transit[index]
            guard !arriving.cancelled, !departing.cancelled else { continue }
            let buffer = Int(((departing.departure.best.timeIntervalSince(arriving.arrival.best)) / 60).rounded(.down))
            let station = departing.origin.name
            let a = arriving.line?.name ?? "Zug", d = departing.line?.name ?? "Zug"
            if buffer < minimumTransfer {
                issues.append(.transferMissed(at: station, arrivingLine: a, departingLine: d, bufferMinutes: buffer))
            } else if buffer < riskTransfer, departing.departure.planned.timeIntervalSince(arriving.arrival.planned) >= Double(riskTransfer * 60) {
                // Only warn about risk when realtime made the transfer tighter than planned.
                issues.append(.transferAtRisk(at: station, arrivingLine: a, departingLine: d, bufferMinutes: buffer))
            }
        }
        return issues
    }
}

/// Updates the times, platforms and cancellations of a journey from current trip data, optionally
/// overlaid with fresher data straight from DB (see `TimetablesClient`) for legs where that helps.
public struct JourneyRefresher: Sendable {
    let provider: CombinedProvider
    let timetables: TimetablesClient?

    public init(provider: CombinedProvider, timetables: TimetablesClient? = nil) {
        self.provider = provider
        self.timetables = timetables
    }

    public func refresh(_ journey: Journey) async -> Journey {
        var updated = journey
        for (index, originalLeg) in journey.legs.enumerated() {
            var leg = originalLeg
            if !leg.isWalking, let tripId = leg.tripId, leg.source != .traewelling,
               let trip = try? await provider.trip(id: tripId, source: leg.source) {
                leg = Self.apply(trip, to: leg)
            }
            // DB Timetables wins wherever it knows the stop; the trip data above only fills in
            // what DB can't match (regional operators, far-off stops).
            if let timetables, let override = await timetables.realtime(for: leg) {
                leg = Self.apply(override, to: leg)
            }
            if let timetables, timetables.canLookUp(leg) {
                let live = await timetables.liveStopovers(for: leg)
                leg.stopovers = live.stopovers
                leg.messages = TrainMessage.merged(leg.messages + live.messages)
            }
            // Neither Transitous nor DB Timetables above ever *inserts* a stop — only bahn.expert
            // reports a Zusatzhalt (an unscheduled stop the train additionally picked up today) at
            // all, so it's the only way one ends up in `leg.stopovers` for the UI to show.
            if !leg.stopovers.isEmpty, let bahnExpert = provider.bahnExpert, let stops = try? await bahnExpert.journeyStops(for: leg) {
                leg.stopovers = BahnExpertClient.inserting(stops, into: leg.stopovers)
            }
            updated.legs[index] = leg
        }
        return updated
    }

    static func apply(_ trip: Trip, to leg: Leg) -> Leg {
        var leg = leg
        if trip.cancelled { leg.cancelled = true }
        // Journeys saved before `tripNumber` existed pick up the real train number here.
        if leg.line?.tripNumber == nil { leg.line?.tripNumber = trip.line?.tripNumber }
        if let start = trip.stopovers.first(where: { $0.station.isSamePlace(as: leg.origin) }) {
            if let departure = start.departure { leg.departure = departure }
            if start.departurePlatform?.best != nil { leg.departurePlatform = start.departurePlatform }
            if start.cancelled { leg.cancelled = true }
        }
        if let end = trip.stopovers.last(where: { $0.station.isSamePlace(as: leg.destination) }) {
            if let arrival = end.arrival { leg.arrival = arrival }
            if end.arrivalPlatform?.best != nil { leg.arrivalPlatform = end.arrivalPlatform }
            if end.cancelled { leg.cancelled = true }
        }
        // Keep the intermediate stops as current as the endpoints.
        for index in leg.stopovers.indices {
            let stop = leg.stopovers[index]
            guard let live = trip.stopovers.first(where: {
                $0.station.isSamePlace(as: stop.station)
                    && $0.arrival?.planned == stop.arrival?.planned && $0.departure?.planned == stop.departure?.planned
            }) else { continue }
            if let arrival = live.arrival { leg.stopovers[index].arrival = arrival }
            if let departure = live.departure { leg.stopovers[index].departure = departure }
            if live.cancelled { leg.stopovers[index].cancelled = true }
        }
        return leg
    }

    static func apply(_ override: TimetablesLegOverride, to leg: Leg) -> Leg {
        var leg = leg
        if let departure = override.departure { leg.departure = departure }
        if let departurePlatform = override.departurePlatform { leg.departurePlatform = departurePlatform }
        if let arrival = override.arrival { leg.arrival = arrival }
        if let arrivalPlatform = override.arrivalPlatform { leg.arrivalPlatform = arrivalPlatform }
        if override.cancelled { leg.cancelled = true }
        // Only what DB reports right now: an earlier refresh's notices may have been lifted since.
        leg.messages = override.messages
        return leg
    }
}
