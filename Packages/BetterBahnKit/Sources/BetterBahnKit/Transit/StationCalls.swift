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
        let during = start...end
        if legs.dropFirst().contains(where: { $0.tripId.flatMap { atOrigin[$0] }.map(during.contains) ?? false }) { return true }
        return legs.dropLast().contains { $0.tripId.flatMap { atDestination[$0] }.map(during.contains) ?? false }
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
