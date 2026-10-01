import Foundation

/// An intermediate stop a journey should be routed through, with an optional minimum time to
/// spend there before the next leg is allowed to depart (e.g. "at least 15 min in Hannover").
public struct ViaWaypoint: Codable, Sendable, Hashable, Identifiable {
    public var id: String { station.id }
    public var station: Station
    public var minStayMinutes: Int
    /// Vehicle types allowed on the leg from this waypoint to the next stop; `nil` uses the search-wide selection.
    public var products: Set<Product>?

    public init(station: Station, minStayMinutes: Int = 0, products: Set<Product>? = nil) {
        self.station = station
        self.minStayMinutes = minStayMinutes
        self.products = products
    }

    var minStay: TimeInterval { TimeInterval(minStayMinutes * 60) }
}

/// Routes a journey through up to a handful of waypoints by searching each leg separately and
/// chaining them, enforcing every waypoint's minimum stay. Where a waypoint has no minimum stay and
/// the same train continues through it, the two halves are shown as one leg. Keeps a small beam of candidates per
/// leg (rather than always just the next departure) so the combined route approximates the
/// overall fastest way through all the points, not merely the first possible one.
public struct ViaRoutePlanner: Sendable {
    public let provider: any TransitProvider
    /// How many full candidate routes to keep while chaining legs (bounds the search).
    public var beamWidth: Int
    /// How many of each leg's own results to branch into.
    public var branchFactor: Int
    /// Vehicle types for every leg that has no waypoint-specific selection.
    public var products: Set<Product>

    public init(provider: any TransitProvider, beamWidth: Int = 3, branchFactor: Int = 2,
                products: Set<Product> = Set(Product.allCases)) {
        self.provider = provider
        self.beamWidth = beamWidth
        self.branchFactor = branchFactor
        self.products = products
    }

    private struct Candidate: Sendable {
        var legs: [Journey]
        var arrival: Date
    }

    /// Finds full routes from `from` to `to` via each waypoint in order, sorted fastest (earliest
    /// arrival) first. Only departure-based search is supported — `date` is always read as the
    /// earliest departure, since "arrive by" doesn't compose cleanly with per-stop minimum stays.
    public func journeys(from: Station, to: Station, via: [ViaWaypoint], date: Date, limit: Int = 5) async throws -> [Journey] {
        let stops = [from] + via.map(\.station) + [to]
        guard stops.count > 2 else {
            let page = try await provider.journeys(JourneyQuery(from: from, to: to, date: date))
            return Array(page.journeys.prefix(limit))
        }

        let provider = provider
        let branchFactor = branchFactor
        var beam = [Candidate(legs: [], arrival: date)]
        for index in 0..<(stops.count - 1) {
            let segmentFrom = stops[index]
            let segmentTo = stops[index + 1]
            let minStay = index == 0 ? 0 : via[index - 1].minStay
            let segmentProducts = index == 0 ? products : (via[index - 1].products ?? products)

            var next: [Candidate] = []
            try await withThrowingTaskGroup(of: [Candidate].self) { group in
                for candidate in beam {
                    let departAfter = candidate.arrival.addingTimeInterval(minStay)
                    group.addTask {
                        let page = try await provider.journeys(JourneyQuery(from: segmentFrom, to: segmentTo, date: departAfter, products: segmentProducts))
                        return page.journeys.prefix(branchFactor).compactMap { option -> Candidate? in
                            guard let arrival = option.arrival?.best else { return nil }
                            return Candidate(legs: candidate.legs + [option], arrival: arrival)
                        }
                    }
                }
                for try await results in group {
                    next.append(contentsOf: results)
                }
            }
            guard !next.isEmpty else { return [] }
            next.sort { $0.arrival < $1.arrival }
            beam = Array(next.prefix(beamWidth))
        }

        let combined = beam.map { candidate in
            var legs: [Leg] = []
            for (index, part) in candidate.legs.enumerated() {
                legs = index > 0 && via[index - 1].minStayMinutes == 0
                    ? Self.joiningThroughTrain(legs, part.legs)
                    : legs + part.legs
            }
            return Journey(legs: legs, source: candidate.legs.first?.source ?? .transitous)
        }
        return Array(combined.sorted { ($0.arrival?.best ?? .distantFuture) < ($1.arrival?.best ?? .distantFuture) }.prefix(limit))
    }

    /// Appends `next` to `legs`, folding the two legs at the seam into one when the same train simply
    /// runs on through the via stop: without a minimum stay there there's no reason to get off, so
    /// "Train 1 A → B, Train 1 B → C" becomes "Train 1 A → C" with B as an intermediate stop.
    static func joiningThroughTrain(_ legs: [Leg], _ next: [Leg]) -> [Leg] {
        guard let last = legs.last, let first = next.first, isThroughTrain(last, first) else { return legs + next }
        var merged = last
        merged.destination = first.destination
        merged.arrival = first.arrival
        merged.arrivalPlatform = first.arrivalPlatform
        merged.direction = first.direction ?? last.direction
        merged.cancelled = last.cancelled || first.cancelled
        if var seam = last.stopovers.last, let onward = first.stopovers.first {
            // The via stop keeps its arrival from the first half and gets its departure from the second.
            seam.departure = onward.departure
            seam.departurePlatform = onward.departurePlatform
            seam.departureCancelled = onward.departureCancelled
            merged.stopovers = last.stopovers.dropLast() + [seam] + first.stopovers.dropFirst()
        } else {
            merged.stopovers = []
        }
        merged.remarks = last.remarks + first.remarks.filter { !last.remarks.contains($0) }
        merged.messages = last.messages + first.messages.filter { !last.messages.contains($0) }
        switch (last.geometry, first.geometry) {
        case let (a?, b?): merged.geometry = a + b
        default: merged.geometry = nil
        }
        return legs.dropLast() + [merged] + next.dropFirst()
    }

    /// Whether `second` is the very train of `first` continuing from where `first` ends.
    static func isThroughTrain(_ first: Leg, _ second: Leg) -> Bool {
        guard !first.isWalking, !second.isWalking, first.destination.isSamePlace(as: second.origin) else { return false }
        let dwell = second.departure.planned.timeIntervalSince(first.arrival.planned)
        guard dwell >= 0, dwell <= 30 * 60 else { return false }
        if let a = first.tripId, let b = second.tripId, a == b { return true }
        guard let line = first.line, let other = second.line, let number = line.number else { return false }
        return line.product == other.product && number == other.number
    }
}
