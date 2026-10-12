import Foundation

/// The trains calling at a search's origin and destination, from both stations' boards. Used to
/// spot detours: changing onto a train that also calls at the origin (Berlin Hbf → Halle → back to
/// Gesundbrunnen on an ICE that stops at Hbf too), or leaving one that also calls at the destination.
public struct StationCalls: Sendable {
    /// Per train: when it leaves the origin (planned).
    var atOrigin: [String: Date]
    /// Per train: when it reaches (or leaves) the destination (planned).
    var atDestination: [String: Date]
    /// Trains you may not board at the origin / leave at the destination.
    var noBoardingAtOrigin: Set<String>
    var noAlightingAtDestination: Set<String>
    /// The origin's departures, including trains you may not board there.
    public var departuresAtOrigin: [BoardEntry]
    public var departuresAtDestination: [BoardEntry]

    public init(departuresAtOrigin: [BoardEntry], departuresAtDestination: [BoardEntry], arrivalsAtDestination: [BoardEntry]) {
        self.departuresAtOrigin = departuresAtOrigin
        self.departuresAtDestination = departuresAtDestination
        atOrigin = Dictionary(departuresAtOrigin.map { ($0.tripId, $0.time.planned) }, uniquingKeysWith: min)
        atDestination = Dictionary((arrivalsAtDestination + departuresAtDestination).map { ($0.tripId, $0.time.planned) },
                                   uniquingKeysWith: min)
        noBoardingAtOrigin = Set(departuresAtOrigin.filter { !$0.access.allowsBoarding }.map(\.tripId))
        noAlightingAtDestination = Set((arrivalsAtDestination + departuresAtDestination)
            .filter { !$0.access.allowsAlighting }.map(\.tripId))
    }

    /// `journey` with "Nur Ausstieg" at the origin and "Nur Einstieg" at the destination marked on its
    /// first and last leg. Transitous' routing doesn't report them (it even offers ICE 806 from Berlin
    /// Hbf to Gesundbrunnen as a normal ride), only its stop times at the station do.
    public func marking(_ journey: Journey) -> Journey {
        var journey = journey
        if let first = journey.legs.first, !first.isWalking, let id = first.tripId, noBoardingAtOrigin.contains(id),
           var stop = first.stopovers.first {
            stop.access = stop.access.allowsAlighting ? .exitOnly : .passThrough
            journey.legs[0].stopovers[0] = stop
        }
        let lastIndex = journey.legs.count - 1
        if let last = journey.legs.last, !last.isWalking, let id = last.tripId, noAlightingAtDestination.contains(id),
           var stop = last.stopovers.last {
            stop.access = stop.access.allowsBoarding ? .entryOnly : .passThrough
            journey.legs[lastIndex].stopovers[last.stopovers.count - 1] = stop
        }
        return journey
    }

    /// Trips ridden from origin to destination in one go, to leave out the expert option's extra
    /// trains the search already has.
    public static func directTripIds(_ journeys: [Journey]) -> Set<String> {
        Set(journeys.compactMap { $0.transitLegs.count == 1 ? $0.transitLegs[0].tripId : nil })
    }

    /// Whether `journey` changes onto a train that also calls at the origin while the journey is
    /// under way, or gets off a train that also calls at the destination. Either way the route loops
    /// back over a station a single train already serves: in Alfred's example the ICE boarded in Halle
    /// runs back through Berlin Hbf (where the timetable allows no boarding) to Gesundbrunnen. The
    /// expert option "Nur Ein-/Ausstieg ignorieren" offers such trains directly instead.
    public func isDetour(_ journey: Journey) -> Bool {
        let legs = journey.transitLegs
        guard legs.count > 1, let start = journey.departure?.planned, let end = journey.arrival?.planned else { return false }
        // Feed data can have an arrival before the departure; `start...end` would then trap.
        func during(_ time: Date) -> Bool { time >= start && time <= end }
        if legs.dropFirst().contains(where: { $0.tripId.flatMap { atOrigin[$0] }.map(during) ?? false }) { return true }
        return legs.dropLast().contains { $0.tripId.flatMap { atDestination[$0] }.map(during) ?? false }
    }
}

public extension TrainPicker {
    /// Loads which trains call at both stations between `start` and `end`.
    func stationCalls(from origin: Station, to destination: Station, start: Date, end: Date) async -> StationCalls {
        let minutes = max(30, Int(end.timeIntervalSince(start) / 60) + 5)
        if let transitous = provider.primary as? TransitousProvider {
            async let atOrigin = try? transitous.calls(at: origin, date: start, duration: minutes)
            async let atDestination = try? transitous.calls(at: destination, date: start, duration: minutes)
            let there = await atDestination
            return StationCalls(departuresAtOrigin: await atOrigin?.departures ?? [],
                                departuresAtDestination: there?.departures ?? [], arrivalsAtDestination: there?.arrivals ?? [])
        }
        async let atOrigin = try? provider.departures(at: origin, date: start, duration: minutes)
        async let departing = try? provider.departures(at: destination, date: start, duration: minutes)
        async let arriving = try? provider.arrivals(at: destination, date: start, duration: minutes)
        return StationCalls(departuresAtOrigin: await atOrigin ?? [], departuresAtDestination: await departing ?? [],
                            arrivalsAtDestination: await arriving ?? [])
    }
}

public extension TrainPicker {
    /// Trains you may not board at `query.from` that don't run to `query.to`, ridden to the stops
    /// closest to it and continued from there with a normal connection, e.g. ICE 204 Hamburg-Harburg →
    /// Hamburg Hbf, then RJ 177 to Berlin. Expert option "Nur Ein-/Ausstieg ignorieren", next to the
    /// direct trains of `journeysIgnoringBoardingRules`. Only the first `maxTrains` such trains leaving
    /// before `end` are tried, getting off at up to `maxAlightStops` stops each.
    func journeysContinuingFromRestrictedTrains(_ query: JourneyQuery, calls: StationCalls, end: Date,
                                                maxTrains: Int = 4, maxAlightStops: Int = 2,
                                                minTransferMinutes: Int = 5) async -> [Journey] {
        let candidates = calls.departuresAtOrigin
            .filter { $0.access == .exitOnly && !$0.cancelled && $0.line.product.isTrain
                && query.products.contains($0.line.filterProduct)
                && $0.time.best >= query.date && $0.time.planned <= end }
            .sorted { $0.time.planned < $1.time.planned }
        var seen = Set<String>()
        let trains = candidates.filter { seen.insert($0.tripId).inserted }.prefix(maxTrains)
        let provider = provider
        let minTransfer = TimeInterval(minTransferMinutes * 60)
        let found = await withTaskGroup(of: [Journey].self) { group in
            for entry in trains {
                group.addTask {
                    guard let trip = try? await provider.trip(id: entry.tripId, source: entry.source),
                          let boardIndex = trip.stopovers.firstIndex(where: { $0.station.isSamePlace(as: query.from) }),
                          !trip.stopovers[(boardIndex + 1)...].contains(where: { $0.station.isSamePlace(as: query.to) })
                    else { return [] }
                    var journeys: [Journey] = []
                    for index in Self.alightIndices(trip: trip, after: boardIndex, target: query.to, limit: maxAlightStops) {
                        guard let ride = trip.leg(fromIndex: boardIndex, toIndex: index), !ride.cancelled else { continue }
                        let departAfter = ride.arrival.best.addingTimeInterval(minTransfer)
                        var onward = query
                        onward.from = ride.destination
                        onward.date = departAfter
                        onward.isArrival = false
                        onward.cursor = nil
                        onward.maxTransfers = query.maxTransfers.map { $0 - 1 }
                        if let limit = onward.maxTransfers, limit < 0 { continue }
                        guard let page = try? await provider.journeys(onward) else { continue }
                        journeys += page.journeys
                            .filter { !$0.isCancelled && ($0.departure?.best ?? .distantPast) >= departAfter.addingTimeInterval(-60)
                                && $0.transitLegs.first?.tripId != trip.id }
                            .sorted { ($0.arrival?.best ?? .distantFuture) < ($1.arrival?.best ?? .distantFuture) }
                            .prefix(2)
                            .map { Journey(legs: [ride] + $0.legs, source: ride.source) }
                    }
                    return journeys
                }
            }
            var all: [Journey] = []
            for await journeys in group { all += journeys }
            return all
        }
        return Self.withoutDominated(found)
    }

    /// Keeps only journeys no other one beats: none leaves at least as late and arrives at least as
    /// early. Of two alike (one train under two names, "RJ 177"/"ICE 177") the first stays. Earliest
    /// arrival first.
    static func withoutDominated(_ journeys: [Journey]) -> [Journey] {
        let sorted = journeys.filter { $0.departure != nil && $0.arrival != nil }.sorted {
            let a = $0.arrival!.best, b = $1.arrival!.best
            return a != b ? a < b : $0.departure!.best > $1.departure!.best
        }
        var latestDeparture = Date.distantPast
        return sorted.filter { journey in
            guard journey.departure!.best > latestDeparture else { return false }
            latestDeparture = journey.departure!.best
            return true
        }
    }

    /// Stops after `boardIndex` to get off at, closest to `target` first; only ones that allow it.
    static func alightIndices(trip: Trip, after boardIndex: Int, target: Station, limit: Int) -> [Int] {
        let candidates = trip.stopovers.indices.filter { index in
            let stop = trip.stopovers[index]
            return index > boardIndex && stop.arrival != nil && !stop.arrivalCancelled && stop.access.allowsAlighting
        }
        guard let goal = target.coordinate else { return Array(candidates.prefix(limit)) }
        return Array(candidates.sorted {
            (trip.stopovers[$0].station.coordinate?.distance(to: goal) ?? .greatestFiniteMagnitude)
                < (trip.stopovers[$1].station.coordinate?.distance(to: goal) ?? .greatestFiniteMagnitude)
        }.prefix(limit))
    }
}
