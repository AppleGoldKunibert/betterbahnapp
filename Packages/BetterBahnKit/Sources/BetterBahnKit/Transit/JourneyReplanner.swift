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

    public init(provider: any TransitProvider) {
        self.provider = provider
    }

    /// Ways onwards from `origin` for someone arriving there at `arrival`, fastest first.
    /// Routes that depart before the arrival (or are cancelled) are dropped.
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
        results = results.filter { ($0.departure?.best ?? .distantPast) >= arrival && !$0.isCancelled }
        return Array(results.prefix(limit))
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
