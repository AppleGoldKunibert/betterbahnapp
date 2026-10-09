import Foundation

/// How the rest of a journey should be re-planned once the user decides to get off somewhere else.
/// Mirrors the options of a normal search (vehicle types, transfer limit, intermediate stops), so a
/// route picked earlier can be adjusted instead of being searched again from scratch.
public struct ReplanOptions: Sendable, Hashable {
    /// Where the journey should end – changeable, e.g. to finish somewhere closer than planned.
    public var destination: Station
    /// Intermediate stops the rest of the route has to pass, each with its own minimum stay.
    public var via: [ViaWaypoint]
    public var products: Set<Product>
    public var maxTransfers: Int?
    /// Minimum time between getting off and the next departure.
    public var minTransferMinutes: Int

    public init(destination: Station, via: [ViaWaypoint] = [], products: Set<Product> = Set(Product.allCases),
                maxTransfers: Int? = nil, minTransferMinutes: Int = 5) {
        self.destination = destination
        self.via = via
        self.products = products
        self.maxTransfers = maxTransfers
        self.minTransferMinutes = minTransferMinutes
    }
}

/// Re-plans the remainder of a journey from a freely chosen exit stop: the legs before it are kept,
/// the leg the user is riding is cut short there, and a new route to the (possibly changed)
/// destination is searched with its own filters.
public struct JourneyReplanner: Sendable {
    public let provider: any TransitProvider
    /// DB's own live delays, laid over the routes found – Transitous' realtime for DB trains can lag
    /// or be missing, which would otherwise suggest transfers that today's delays already broke.
    public let timetables: TimetablesClient?

    public init(provider: any TransitProvider, timetables: TimetablesClient? = nil) {
        self.provider = provider
        self.timetables = timetables
    }

    /// Ways onwards from `origin` for someone arriving there at `arrival`, fastest first.
    /// Times are live (see `timetables`); routes that depart before the arrival, are cancelled or
    /// contain a transfer the current delays make impossible are dropped.
    public func continuations(from origin: Station, arriving arrival: Date, options: ReplanOptions,
                              limit: Int = 8) async throws -> [Journey] {
        let departAfter = arrival.addingTimeInterval(TimeInterval(options.minTransferMinutes * 60))
        var results: [Journey]
        if options.via.isEmpty {
            let page = try await provider.journeys(JourneyQuery(
                from: origin, to: options.destination, date: departAfter,
                products: options.products, maxTransfers: options.maxTransfers))
            results = page.journeys
        } else {
            // Via routing searches each section on its own; the transfer limit applies to the whole route.
            results = try await ViaRoutePlanner(provider: provider, products: options.products).journeys(
                from: origin, to: options.destination, via: options.via, date: departAfter, limit: limit)
            if let maxTransfers = options.maxTransfers {
                results = results.filter { $0.transfers <= maxTransfers }
            }
        }
        results = await withRealtime(results)
        results = results.filter { journey in
            (journey.departure?.best ?? .distantPast) >= arrival && !journey.isCancelled
                && !journey.connectionIssues().contains(where: \.isBlocking)
        }
        return Array(Self.fastestFirst(results).prefix(limit))
    }

    /// Earliest arrival first (live times), without routes another one beats outright: one that leaves
    /// no earlier, arrives no later and changes no more often (#225). Searches list by departure, so
    /// a slow early route used to come first although a later one gets there sooner.
    public static func fastestFirst(_ journeys: [Journey]) -> [Journey] {
        func times(_ journey: Journey) -> (departure: Date, arrival: Date) {
            (journey.departure?.best ?? .distantPast, journey.arrival?.best ?? .distantFuture)
        }
        let sorted = journeys.enumerated().sorted { a, b in
            let ta = times(a.element), tb = times(b.element)
            if ta.arrival != tb.arrival { return ta.arrival < tb.arrival }
            if ta.departure != tb.departure { return ta.departure > tb.departure }
            if a.element.transfers != b.element.transfers { return a.element.transfers < b.element.transfers }
            return a.offset < b.offset
        }.map(\.element)
        var kept: [Journey] = []
        for journey in sorted {
            let own = times(journey)
            // Everything kept so far arrives no later; it wins if it also leaves no earlier with no more changes.
            let beaten = kept.contains { other in
                times(other).departure >= own.departure && other.transfers <= journey.transfers
            }
            if !beaten { kept.append(journey) }
        }
        return kept
    }

    /// `journeys` with DB Timetables' live times, platforms and cancellations laid over each train,
    /// in the same order. Unchanged without a Timetables client.
    public func withRealtime(_ journeys: [Journey]) async -> [Journey] {
        guard let timetables else { return journeys }
        return await withTaskGroup(of: (Int, Journey).self) { group in
            for (index, journey) in journeys.enumerated() {
                group.addTask {
                    var updated = journey
                    for (legIndex, leg) in journey.legs.enumerated() {
                        if let override = await timetables.realtime(for: leg) {
                            updated.legs[legIndex] = JourneyRefresher.apply(override, to: leg)
                        }
                    }
                    return (index, updated)
                }
            }
            var updated = journeys
            for await (index, journey) in group { updated[index] = journey }
            return updated
        }
    }

    /// Puts a re-planned journey back together: everything before `legIndex` stays untouched, the
    /// leg there is replaced by `exitLeg` (the same ride, ending at the new exit), and
    /// `continuation` is appended. A continuation that simply stays on the same train is merged
    /// into the ride instead of being listed as a second leg.
    public static func rebuild(_ journey: Journey, replacingLegAt legIndex: Int, with exitLeg: Leg,
                               continuation: Journey?) -> Journey {
        var legs = Array(journey.legs.prefix(legIndex))
        legs.append(exitLeg)
        guard var rest = continuation?.legs, !rest.isEmpty else {
            return Journey(legs: legs, source: journey.source)
        }
        if let next = rest.first, let tripId = exitLeg.tripId, next.tripId == tripId, next.source == exitLeg.source {
            var merged = exitLeg
            merged.destination = next.destination
            merged.arrival = next.arrival
            merged.arrivalPlatform = next.arrivalPlatform
            merged.stopovers = exitLeg.stopovers + next.stopovers.dropFirst()
            legs[legs.count - 1] = merged
            rest.removeFirst()
        }
        return Journey(legs: legs + rest, source: journey.source)
    }
}

/// One way of finishing the journey: leave the train at `exit` and carry on from there.
public struct ExitOption: Sendable, Identifiable {
    public var id: String { exit.id }
    /// The stop to get off at.
    public var exit: Stopover
    /// The ride from where the traveller boarded up to that stop.
    public var ride: Leg
    /// How to go on; `nil` when the exit already is the destination.
    public var continuation: Journey?
    /// When the destination is reached this way.
    public var arrival: Date

    public init(exit: Stopover, ride: Leg, continuation: Journey?, arrival: Date) {
        self.exit = exit
        self.ride = ride
        self.continuation = continuation
        self.arrival = arrival
    }
}

public extension JourneyReplanner {
    /// How long a suggested exit has to save before it's worth mentioning.
    static var worthMentioning: TimeInterval { 5 * 60 }

    /// Ways to reach `options.destination` by getting off this train somewhere, earliest arrival
    /// first.
    ///
    /// Only stops *after* `boarding` that the train hasn't called at yet are considered – a station
    /// the traveller has already left can't be routed from. When a new destination lies behind the
    /// planned exit, this is what finds the earlier stop to leave at instead of riding on and
    /// coming back.
    func exitOptions(on trip: Trip, boardingAt boarding: Station, notBefore now: Date,
                     options: ReplanOptions, maxCandidates: Int = 6, limit: Int = 3) async -> [ExitOption] {
        guard let boardIndex = trip.stopovers.firstIndex(where: { $0.station.isSamePlace(as: boarding) }) else { return [] }
        var rest = trip.stopovers[(boardIndex + 1)...].filter { stop in
            guard let arrival = stop.arrival, !stop.arrivalCancelled, stop.access.allowsAlighting else { return false }
            return arrival.best >= now
        }
        // The destination itself is always worth trying; the other slots go to the stops closest to it.
        var head: [Stopover] = []
        if let index = rest.firstIndex(where: { $0.station.isSamePlace(as: options.destination) }) {
            head = [rest.remove(at: index)]
        }
        let slots = max(0, maxCandidates - head.count)
        if rest.count > slots {
            if let goal = options.destination.coordinate {
                rest.sort {
                    ($0.station.coordinate?.distance(to: goal) ?? .greatestFiniteMagnitude)
                        < ($1.station.coordinate?.distance(to: goal) ?? .greatestFiniteMagnitude)
                }
            }
            rest = Array(rest.prefix(slots))
        }

        let candidates = head + rest
        let planner = self
        let found = await withTaskGroup(of: ExitOption?.self) { group in
            var iterator = candidates.makeIterator()
            var running = 0
            var results: [ExitOption] = []
            func addNext() -> Bool {
                guard let stop = iterator.next() else { return false }
                group.addTask { await planner.option(for: stop, on: trip, boardingAt: boarding, options: options) }
                return true
            }
            // At most 4 parallel searches, like the other planners, to stay within API rate limits.
            while running < 4, addNext() { running += 1 }
            while let result = await group.next() {
                if let result { results.append(result) }
                _ = addNext()
            }
            return results
        }
        return Array(found.sorted { $0.arrival < $1.arrival }.prefix(limit))
    }

    private func option(for stop: Stopover, on trip: Trip, boardingAt boarding: Station,
                        options: ReplanOptions) async -> ExitOption? {
        guard let ride = trip.leg(from: boarding, to: stop.station) else { return nil }
        if stop.station.isSamePlace(as: options.destination) {
            return ExitOption(exit: stop, ride: ride, continuation: nil, arrival: ride.arrival.best)
        }
        guard let onward = try? await continuations(from: stop.station, arriving: ride.arrival.best,
                                                    options: options, limit: 1).first,
              let arrival = onward.arrival?.best else { return nil }
        return ExitOption(exit: stop, ride: ride, continuation: onward, arrival: arrival)
    }
}
