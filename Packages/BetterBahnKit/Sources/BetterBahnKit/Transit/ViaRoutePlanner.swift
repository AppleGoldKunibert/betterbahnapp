import Foundation

/// An intermediate stop a journey should be routed through, with an optional minimum time to
/// spend there before the next leg is allowed to depart (e.g. "at least 15 min in Hannover").
public struct ViaWaypoint: Codable, Sendable, Hashable, Identifiable {
    public var id: String { station.id }
    public var station: Station
    public var minStayMinutes: Int

    public init(station: Station, minStayMinutes: Int = 0) {
        self.station = station
        self.minStayMinutes = minStayMinutes
    }

    var minStay: TimeInterval { TimeInterval(minStayMinutes * 60) }
}

/// Routes a journey through up to a handful of waypoints by searching each leg separately and
/// chaining them, enforcing every waypoint's minimum stay. Keeps a small beam of candidates per
/// leg (rather than always just the next departure) so the combined route approximates the
/// overall fastest way through all the points, not merely the first possible one.
public struct ViaRoutePlanner: Sendable {
    public let provider: any TransitProvider
    /// How many full candidate routes to keep while chaining legs (bounds the search).
    public var beamWidth: Int
    /// How many of each leg's own results to branch into.
    public var branchFactor: Int

    public init(provider: any TransitProvider, beamWidth: Int = 3, branchFactor: Int = 2) {
        self.provider = provider
        self.beamWidth = beamWidth
        self.branchFactor = branchFactor
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

            var next: [Candidate] = []
            try await withThrowingTaskGroup(of: [Candidate].self) { group in
                for candidate in beam {
                    let departAfter = candidate.arrival.addingTimeInterval(minStay)
                    group.addTask {
                        let page = try await provider.journeys(JourneyQuery(from: segmentFrom, to: segmentTo, date: departAfter))
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
            Journey(legs: candidate.legs.flatMap(\.legs), source: candidate.legs.first?.source ?? .transitous)
        }
        return Array(combined.sorted { ($0.arrival?.best ?? .distantFuture) < ($1.arrival?.best ?? .distantFuture) }.prefix(limit))
    }
}
