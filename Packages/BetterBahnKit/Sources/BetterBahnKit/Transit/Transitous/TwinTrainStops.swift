import Foundation

/// Stops (and platforms) a long-distance train's own feed leaves out. Transitous routes Berlin → Praha over ÖBB's copy
/// of RJ 177 at times, which lists only Berlin Hbf, Südkreuz, Děčín and Praha-Holešovice, while DB's
/// copy (DELFI's "ICE 177", leaving Berlin Hbf at the same minute) has Dresden-Neustadt, Dresden Hbf,
/// Bad Schandau and Ústí as well. The same train from another feed is found on the departures at the
/// leg's start, by its number and planned time, and the stops only it has are inserted in between.
extension TransitousProvider {
    /// How far the same stop's planned time may differ between two feeds (see `czechTimetableTolerance`).
    static let twinStopTolerance: TimeInterval = 5 * 60

    /// Whether `leg` is a long-distance train from a feed that may leave out stops: not DB's own (DELFI)
    /// nor the Czech timetable, which list all of theirs.
    static func mayLackStops(_ leg: Leg) -> Bool {
        guard !leg.isWalking, !leg.cancelled, leg.source == .transitous, let line = leg.line, line.number != nil,
              [.highSpeed, .longDistance].contains(line.product), leg.stopovers.count >= 2,
              let tripId = leg.tripId else { return false }
        return !tripId.contains("_de-DELFI_") && !tripId.contains(czechTimetableFeed)
    }

    /// `leg` with the stops another feed's copy of its train has in between (see above); unchanged if
    /// there is none or it has no more stops.
    public func fillingMissingStops(in leg: Leg) async -> Leg {
        guard Self.mayLackStops(leg), let twin = await twinStops(for: leg) else { return leg }
        return Self.fillingMissingStops(in: leg, from: twin)
    }

    /// Like `fillingMissingStops(in:)` for the whole run of `leg`'s train.
    public func fillingMissingStops(in trip: Trip, of leg: Leg) async -> Trip {
        guard Self.mayLackStops(leg), trip.id == leg.tripId, let twin = await twinStops(for: leg),
              let stops = Self.insertingMissingStops(into: trip.stopovers, from: twin) else { return trip }
        var trip = trip
        trip.stopovers = stops
        return trip
    }

    /// For each leg that may lack stops, the stops of its train's copy from another feed, keyed by
    /// `Leg.id` (for `fillingMissingStops(in:from:)`). Legs without one are left out.
    public func twinStops(for legs: [Leg]) async -> [String: [Stopover]] {
        let candidates = Dictionary(legs.filter(Self.mayLackStops).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !candidates.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, [Stopover]?).self) { group in
            for leg in candidates.values {
                group.addTask { (leg.id, await twinStops(for: leg)) }
            }
            var result: [String: [Stopover]] = [:]
            for await (id, stops) in group { if let stops { result[id] = stops } }
            return result
        }
    }

    /// The stops of the copy of `leg`'s train from another feed that adds the most stops to it;
    /// nil if there is none. Cached for the day: timetables don't change in between.
    func twinStops(for leg: Leg) async -> [Stopover]? {
        guard let tripId = leg.tripId else { return nil }
        let key = "\(tripId)|\(leg.origin.id)|\(leg.departure.planned.timeIntervalSince1970)"
        let found = try? await twinStopsCache.value(for: key, maxAge: 12 * 3600) {
            try await findTwinStops(for: leg)
        }
        guard let found, !found.isEmpty else { return nil }
        return found
    }

    private func findTwinStops(for leg: Leg) async throws -> [Stopover]? {
        guard let number = leg.line?.number, let tripId = leg.tripId else { return nil }
        let planned = leg.departure.planned
        let stopTimes = try await fetchStopTimes(stopId: leg.origin.id, date: planned.addingTimeInterval(-60), duration: 2,
                                                 kind: .departures, modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"],
                                                 count: 20)
        let twins = Self.twinCandidates(of: tripId, number: number, departing: planned, in: stopTimes)
        var best: (stops: [Stopover], added: Int)?
        for twin in twins.prefix(3) {
            guard let trip = try? await trip(id: twin.tripId),
                  let merged = Self.insertingMissingStops(into: leg.stopovers, from: trip.stopovers) else { continue }
            // The copy adding the most stops wins; one adding only platforms still counts.
            let added = merged.count - leg.stopovers.count
            if best.map({ added > $0.added }) ?? true { best = (trip.stopovers, added) }
        }
        return best?.stops
    }

    /// Other feeds' rows of train `number` leaving at `planned` (the leg's own trip left out).
    static func twinCandidates(of tripId: String, number: String, departing planned: Date, in stopTimes: [MStopTime]) -> [MStopTime] {
        var seen: Set<String> = [tripId]
        return stopTimes.filter { stopTime in
            stopTime.place.scheduledDeparture == planned && stopTime.lineInfo.toLine().number == number
                && stopTime.cancelled != true && stopTime.tripCancelled != true && seen.insert(stopTime.tripId).inserted
        }
    }

    // MARK: Merging

    /// `leg` with the stops `twin` (its train from another feed) has between two of its own, and the
    /// platforms its stops lack where `twin` has them. Unchanged if `twin` doesn't match it.
    public static func fillingMissingStops(in leg: Leg, from twin: [Stopover]) -> Leg {
        guard let stops = insertingMissingStops(into: leg.stopovers, from: twin) else { return leg }
        var leg = leg
        leg.stopovers = stops
        if leg.departurePlatform?.best == nil, let first = stops.first, first.station.isSamePlace(as: leg.origin),
           first.departurePlatform?.best != nil {
            leg.departurePlatform = first.departurePlatform
        }
        if leg.arrivalPlatform?.best == nil, let last = stops.last, last.station.isSamePlace(as: leg.destination),
           last.arrivalPlatform?.best != nil {
            leg.arrivalPlatform = last.arrivalPlatform
        }
        return leg
    }

    /// `own` with `twin`'s stops inserted between two neighbouring stops of `own` that `twin` has
    /// too, in its order, and with platforms `own` lacks at those taken from `twin`. Nil when `twin`
    /// adds neither a stop nor a platform, or doesn't have `own`'s stops in the same order (another route).
    static func insertingMissingStops(into own: [Stopover], from twin: [Stopover]) -> [Stopover]? {
        // Where each of `own`'s stops is in `twin`, walking forward.
        var positions: [Int?] = []
        var next = 0
        for stop in own {
            let position = twin.indices.dropFirst(next).first { isSameStop(stop, twin[$0]) }
            positions.append(position)
            if let position { next = position + 1 }
        }
        guard positions.compactMap({ $0 }).count >= 2 else { return nil }
        var result: [Stopover] = []
        var changed = false
        for (index, stop) in own.enumerated() {
            var stop = stop
            if let position = positions[index] {
                let other = twin[position]
                if stop.arrival != nil, stop.arrivalPlatform?.best == nil, other.arrivalPlatform?.best != nil {
                    stop.arrivalPlatform = other.arrivalPlatform
                    changed = true
                }
                if stop.departure != nil, stop.departurePlatform?.best == nil, other.departurePlatform?.best != nil {
                    stop.departurePlatform = other.departurePlatform
                    changed = true
                }
            }
            result.append(stop)
            guard index + 1 < own.count, let from = positions[index], let to = positions[index + 1], to > from + 1 else { continue }
            let between = twin[(from + 1)..<to].filter { !$0.cancelled }
            result += between
            changed = changed || !between.isEmpty
        }
        return changed ? result : nil
    }

    /// The same stop in two feeds: the same place, at about the same planned time.
    private static func isSameStop(_ a: Stopover, _ b: Stopover) -> Bool {
        guard a.station.isSamePlace(as: b.station) else { return false }
        let pairs = [(a.arrival, b.arrival), (a.departure, b.departure)].compactMap { pair -> (Date, Date)? in
            guard let x = pair.0?.planned, let y = pair.1?.planned else { return nil }
            return (x, y)
        }
        return !pairs.isEmpty && pairs.allSatisfy { abs($0.0.timeIntervalSince($0.1)) <= twinStopTolerance }
    }
}
