import Foundation

/// Builds the journey of one travel day of a `RegularTrip` (#397): the same trains, looked up on the
/// boarding station's departures at the template's time of day, so the saved journey has that day's
/// runs (trip IDs, platforms, live times) and refreshes like any other.
public struct RegularTripPlanner: Sendable {
    let provider: CombinedProvider
    /// A board entry only counts as the train when it leaves this close to the planned time.
    static let tolerance: TimeInterval = 3 * 60

    public init(provider: CombinedProvider) {
        self.provider = provider
    }

    /// The day's journey. A train that can't be found that day keeps its planned times from the template
    /// (DB's live data still fills it in by name and station); throws only when none of them is found,
    /// e.g. offline.
    public func journey(for trip: RegularTrip, on day: Date) async throws -> Journey {
        let template = trip.template
        let (legs, found) = await withTaskGroup(of: (Int, Leg?).self) { group in
            for (index, leg) in template.legs.enumerated() where !leg.isWalking {
                let planned = trip.plannedLeg(leg, on: day)
                group.addTask { (index, await resolve(planned)) }
            }
            var legs = template.legs.map { trip.plannedLeg($0, on: day) }
            var found = 0
            for await (index, leg) in group {
                guard let leg else { continue }
                legs[index] = leg
                found += 1
            }
            return (legs, found)
        }
        guard found > 0 || template.transitLegs.isEmpty else {
            throw TransitError.notFound(template.transitLegs.first?.line?.displayName ?? String(kit: "Zug"))
        }
        return Journey(legs: legs, source: template.source)
    }

    /// The run of `planned`'s train that day, from its boarding station's departures.
    private func resolve(_ planned: Leg) async -> Leg? {
        let start = planned.departure.planned
        guard let entries = try? await provider.departuresForTrainLookup(at: planned.origin, date: start.addingTimeInterval(-10 * 60),
                                                                         duration: 30) else { return nil }
        for entry in Self.candidates(in: entries, for: planned) {
            if let trip = try? await provider.trip(id: entry.tripId, source: entry.source),
               let leg = Self.leg(of: trip, like: planned) {
                return leg
            }
        }
        return nil
    }

    /// The board entries that can be `planned`'s train: same train, leaving within `tolerance` of its
    /// planned time; the same run number first, then the closest time.
    static func candidates(in entries: [BoardEntry], for planned: Leg) -> [BoardEntry] {
        let wanted = planned.departure.planned
        return entries
            .filter { abs($0.time.planned.timeIntervalSince(wanted)) <= tolerance && isSameTrain(planned.line, $0.line) }
            .sorted { a, b in
                let aRun = sameRun(planned.line, a.line), bRun = sameRun(planned.line, b.line)
                if aRun != bRun { return aRun }
                return abs(a.time.planned.timeIntervalSince(wanted)) < abs(b.time.planned.timeIntervalSince(wanted))
            }
    }

    /// The part of `trip` that `planned` rides: boarding at the visit of its origin closest to its planned
    /// departure (a ring line passes a station more than once), to the next visit of its destination.
    static func leg(of trip: Trip, like planned: Leg) -> Leg? {
        let wanted = planned.departure.planned
        let boarding = trip.stopovers.indices.filter { index in
            guard let departure = trip.stopovers[index].departure else { return false }
            return trip.stopovers[index].station.isSamePlace(as: planned.origin)
                && abs(departure.planned.timeIntervalSince(wanted)) <= tolerance
        }.min { a, b in
            abs(trip.stopovers[a].departure!.planned.timeIntervalSince(wanted))
                < abs(trip.stopovers[b].departure!.planned.timeIntervalSince(wanted))
        }
        guard let start = boarding,
              let end = trip.stopovers[(start + 1)...].firstIndex(where: { $0.station.isSamePlace(as: planned.destination) })
        else { return nil }
        return trip.leg(fromIndex: start, toIndex: end)
    }

    /// The same train: the same run number, or the same name ("RE 3" every day, even where the run number
    /// changes on Fridays).
    public static func isSameTrain(_ a: Line?, _ b: Line?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if sameRun(a, b) { return true }
        return a.allNames.contains { name in b.allNames.contains { Line.normalize($0) == Line.normalize(name) } }
    }

    static func sameRun(_ a: Line?, _ b: Line?) -> Bool {
        guard let first = a?.dispatchNumber, let second = b?.dispatchNumber else { return false }
        return TimetablesClient.category(from: a?.name ?? "") == TimetablesClient.category(from: b?.name ?? "") && first == second
    }
}
