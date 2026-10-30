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
        case .transferMissed(let at, _, _, _): String(kit: "Umstieg in %@ klappt nicht mehr", at)
        case .transferAtRisk(let at, _, _, _): String(kit: "Umstieg in %@ wird knapp", at)
        case .legCancelled(let line, _, _): String(kit: "%@ fällt aus", Self.shown(line))
        }
    }

    public var message: String {
        switch self {
        case .transferMissed(_, let arriving, let departing, let buffer):
            buffer < 0
                ? String(kit: "%@ fährt %lld Min. bevor %@ ankommt.", Self.shown(departing), -buffer, Self.shown(arriving))
                : String(kit: "Nur %lld Min. zum Umsteigen von %@ in %@.", buffer, Self.shown(arriving), Self.shown(departing))
        case .transferAtRisk(_, let arriving, let departing, let buffer):
            String(kit: "%lld Min. zum Umsteigen von %@ in %@.", buffer, Self.shown(arriving), Self.shown(departing))
        case .legCancelled(_, let from, let to):
            String(kit: "Die Fahrt von %@ nach %@ findet nicht statt.", from, to)
        }
    }

    /// A line name for display: "Zug" (no line known) is kept German in the issue, which is matched by it.
    private static func shown(_ line: String) -> String {
        line == "Zug" ? String(kit: "Zug") : line
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
            issues.append(.legCancelled(line: leg.line?.name ?? "Zug", from: leg.origin.displayName, to: leg.destination.displayName))
        }
        guard transit.count > 1 else { return issues }
        for index in 1..<transit.count {
            let arriving = transit[index - 1], departing = transit[index]
            guard !arriving.cancelled, !departing.cancelled else { continue }
            let buffer = Int(((departing.departure.best.timeIntervalSince(arriving.arrival.best)) / 60).rounded(.down))
            let station = departing.origin.displayName
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

    /// The transit leg an issue is about: the arriving train of a (missed or tight) transfer, or the
    /// cancelled train. Matches the way `connectionIssues()` names stations and lines, so a raw name
    /// like "S+U Gesundbrunnen Bhf (Berlin)" still finds the issue's "Berlin Gesundbrunnen".
    func leg(for issue: ConnectionIssue) -> Leg? {
        let transit = transitLegs
        func lineName(_ leg: Leg) -> String { leg.line?.name ?? "Zug" }
        switch issue {
        case .transferMissed(let at, let arriving, let departing, _), .transferAtRisk(let at, let arriving, let departing, _):
            guard transit.count > 1 else { return nil }
            return (1..<transit.count).first {
                lineName(transit[$0 - 1]) == arriving && lineName(transit[$0]) == departing
                    && transit[$0].origin.displayName == at
            }.map { transit[$0 - 1] }
        case .legCancelled(let line, let from, let to):
            return transit.first {
                $0.cancelled && lineName($0) == line && $0.origin.displayName == from && $0.destination.displayName == to
            }
        }
    }

    /// Over 10 minutes after its (realtime) arrival.
    func isOver(now: Date = .now) -> Bool {
        (arrival?.best ?? .distantFuture).addingTimeInterval(10 * 60) < now
    }

    /// `connectionIssues()` to show: a journey that is over only lists its cancellations. How its
    /// transfers went is history then, and the last live data of its trains is often incomplete (DB
    /// drops a train's changes a few hours after it ran), so they'd show as missed though they worked.
    func currentIssues(now: Date = .now) -> [ConnectionIssue] {
        let issues = connectionIssues()
        guard isOver(now: now) else { return issues }
        return issues.filter { if case .legCancelled = $0 { true } else { false } }
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

    public func refresh(_ journey: Journey, now: Date = .now) async -> Journey {
        // Journeys saved before "RJ 177" stopped counting as coupled to its DB twin "ICE 177"
        // (`Line.isSameTrain(as:)`) drop that entry; a leg left without any is looked up again.
        let journey = Self.withoutSelfCoupling(journey)
        var updated = journey
        // Coupled trains the search had no time to find (see `CombinedProvider.journeys`).
        async let coupled = provider.coupledTrains(in: [journey], deadline: .seconds(6))
        // Legs are looked up side by side, so a journey with transfers loads as fast as its slowest leg.
        await withTaskGroup(of: (Int, Leg).self) { group in
            for (index, leg) in journey.legs.enumerated() {
                group.addTask { (index, await refresh(leg, now: now)) }
            }
            for await (index, leg) in group { updated.legs[index] = leg }
        }
        // Journeys saved from results where bahn.de didn't answer in time keep Transitous' generic
        // names (e.g. "ICE 175" for the Railjet "RJ 175"); bahn.de's answers are cached for the day.
        if let bahnDe = provider.bahnDe, let named = await bahnDe.correctingTrainNames(in: [updated]).first {
            updated = named
        }
        return CombinedProvider.applying(await coupled, to: [updated]).first ?? updated
    }

    static func withoutSelfCoupling(_ journey: Journey) -> Journey {
        var journey = journey
        for index in journey.legs.indices {
            journey.legs[index].line = journey.legs[index].line?.withoutSelfCoupling
        }
        return journey
    }

    /// Only what `connectionIssues()` looks at: each leg's times, platforms and cancellation at its
    /// ends, without its stops, bahn.de's Zusatzhalte or train names. Light enough to check every
    /// search result on screen for whether it can still be made.
    public func refreshEnds(_ journey: Journey, now: Date = .now) async -> Journey {
        var updated = journey
        await withTaskGroup(of: (Int, Leg).self) { group in
            for (index, leg) in journey.legs.enumerated() where !leg.isWalking {
                group.addTask { (index, await refreshEnds(of: leg, now: now)) }
            }
            for await (index, leg) in group { updated.legs[index] = leg }
        }
        return updated
    }

    /// A search result whose live data can still change whether it works: not over yet and starting
    /// within the next 12 hours (further ahead there is no realtime beyond what the search had).
    public static func isWorthLiveCheck(_ journey: Journey, now: Date = .now) -> Bool {
        guard let first = journey.transitLegs.first, let last = journey.transitLegs.last else { return false }
        return first.departure.planned <= now.addingTimeInterval(12 * 3600) && last.arrival.best >= now
    }

    /// `live` with the platforms `base` knows where live has none: search results get missing
    /// platforms filled in while their live check is still loading (from the version before).
    public static func keepingPlatforms(of base: Journey, in live: Journey) -> Journey {
        guard base.id == live.id else { return live }
        var merged = live
        for index in merged.legs.indices {
            if merged.legs[index].departurePlatform?.best == nil { merged.legs[index].departurePlatform = base.legs[index].departurePlatform }
            if merged.legs[index].arrivalPlatform?.best == nil { merged.legs[index].arrivalPlatform = base.legs[index].arrivalPlatform }
        }
        return merged
    }

    private func refreshEnds(of originalLeg: Leg, now: Date) async -> Leg {
        guard !Self.isLongOver(originalLeg, now: now) else { return originalLeg }
        var leg = Self.droppingInferredOnTime(originalLeg, now: now)
        if !leg.isWalking, leg.tripId != nil, leg.source != .traewelling,
           let trip = try? await provider.trip(for: leg) {
            leg = Self.apply(trip, to: leg)
            if let beyond = await provider.directionBeyondBorder(of: trip, deadline: .seconds(3)) { leg.direction = beyond }
        }
        let timetables = TimetablesClient.knowsChanges(until: leg.arrival.planned, now: now) ? self.timetables : nil
        // DB Timetables wins wherever it knows the stop; the trip data above only fills in
        // what DB can't match (regional operators, far-off stops).
        if let timetables, let override = await timetables.realtime(for: leg, now: now) {
            leg = Self.apply(override, to: leg)
        }
        return leg
    }

    /// A leg that arrived over 30 minutes ago keeps what was last seen live. Later answers only lose
    /// data: DB drops a train's changes a few hours after it ran and Transitous' realtime runs out, so
    /// one leg of a finished journey could fall back to the timetable while the other kept its delay,
    /// and a transfer that worked showed as missed.
    static func isLongOver(_ leg: Leg, now: Date) -> Bool {
        leg.arrival.best.addingTimeInterval(30 * 60) < now
    }

    /// The leg with every source's live data: its ends from the fresh trip and DB Timetables (`refreshEnds`),
    /// then its stop sequence through `LiveRun`, the same way the trip view loads the whole run, so a journey
    /// card and the run opened from it agree. The leg as it was is the baseline: what the fresh answers lack
    /// (a delay seen earlier, a platform, a Zusatzhalt) stays.
    private func refresh(_ originalLeg: Leg, now: Date) async -> Leg {
        guard !Self.isLongOver(originalLeg, now: now) else { return originalLeg }
        var leg = await refreshEnds(of: originalLeg, now: now)
        // Repaired here too, as bahn.de below isn't always asked or doesn't always answer.
        leg.stopovers = BahnDeClient.droppingOutlyingZusatzhalte(from: leg.stopovers)
        guard !leg.isWalking, let run = Self.run(of: leg) else { return leg }
        let baseline = Self.run(of: Self.droppingInferredOnTime(originalLeg, now: now))
        let live = await LiveRun(provider: provider, timetables: timetables).refresh(run, baseline: baseline, wholeRun: false, now: now)
        return Self.applying(live, to: leg)
    }

    /// The part of the train's run `leg` rides, for `LiveRun`: its stops, carrying its ends' live data
    /// (`syncingEnds`), or just its two ends when it was saved without stops.
    static func run(of leg: Leg) -> Trip? {
        syncingEnds(of: leg, toStopovers: true).savedTrip
    }

    /// `leg` with the run `LiveRun` refreshed: its stops (unless it never had any), notices and night-train
    /// mark, and its ends synced from the first and last stop (`syncingEnds`), with their platforms where the
    /// leg lacks one — or throughout for a night train of another railway, whose feed's platforms bahn.de's replace.
    static func applying(_ run: Trip, to leg: Leg) -> Leg {
        var leg = leg
        // A leg saved without stops went through as its two ends (`run(of:)`), which aren't stops to show.
        if leg.stopovers.count >= 2 { leg.stopovers = run.stopovers }
        leg.messages = run.messages
        if run.line?.nightRail == true { leg.line?.nightRail = true }
        let platformsOnly = BahnDeClient.takesOnlyPlatforms(leg.line)
        if let first = run.stopovers.first(where: { $0.station.isSamePlace(as: leg.origin) && $0.departure?.planned == leg.departure.planned }) {
            if let departure = first.departure { leg.departure = departure }
            if first.departurePlatform?.best != nil, platformsOnly || leg.departurePlatform?.best == nil {
                leg.departurePlatform = first.departurePlatform
            }
            // The leg's ends take DB's names like its stops (see `TwinTrainStops.swift`).
            if first.station.id.hasPrefix("de-DELFI_") { leg.origin.name = first.station.name }
        }
        if let last = run.stopovers.last(where: { $0.station.isSamePlace(as: leg.destination) && $0.arrival?.planned == leg.arrival.planned }) {
            if let arrival = last.arrival { leg.arrival = arrival }
            if last.arrivalPlatform?.best != nil, platformsOnly || leg.arrivalPlatform?.best == nil {
                leg.arrivalPlatform = last.arrivalPlatform
            }
            if last.station.id.hasPrefix("de-DELFI_") { leg.destination.name = last.station.name }
        }
        return leg
    }

    /// Copies the leg's departure/arrival onto its first/last stopover (`toStopovers`) or back, when
    /// those stopovers are its origin and destination at the same planned times. The DB lookups for
    /// the leg's ends and for its stops are separate requests; one of them can fail (a big station's
    /// `fchg` is large and can time out) while the other gets through. Synced both ways, the leg's
    /// ends keep whichever delay DB reported, as the trip view does (#76: an S7 to Hamburg Hbf
    /// ended "+0" while its stops and the trip view had +3).
    static func syncingEnds(of leg: Leg, toStopovers: Bool) -> Leg {
        var leg = leg
        if let first = leg.stopovers.indices.first, leg.stopovers[first].station.isSamePlace(as: leg.origin),
           leg.stopovers[first].departure?.planned == leg.departure.planned {
            if toStopovers { leg.stopovers[first].departure = leg.departure }
            else if let departure = leg.stopovers[first].departure { leg.departure = departure }
        }
        if let last = leg.stopovers.indices.last, leg.stopovers[last].station.isSamePlace(as: leg.destination),
           leg.stopovers[last].arrival?.planned == leg.arrival.planned {
            if toStopovers { leg.stopovers[last].arrival = leg.arrival }
            else if let arrival = leg.stopovers[last].arrival { leg.arrival = arrival }
        }
        return leg
    }

    /// A leg within the next week missing a platform somewhere, which bahn.de may know (see `LiveRun`).
    static func needsPlatforms(_ leg: Leg, now: Date = .now) -> Bool {
        LiveRun.needsPlatforms(leg, now: now)
    }

    /// A leg departing within the next 12 hours or still underway — the only ones a Zusatzhalt
    /// lookup is worth a bahn.de request for (see `LiveRun`).
    static func isRunningSoon(_ leg: Leg, now: Date = .now) -> Bool {
        LiveRun.isRunningSoon(leg, now: now)
    }

    static func apply(_ trip: Trip, to leg: Leg) -> Leg {
        var leg = leg
        if trip.cancelled { leg.cancelled = true }
        // Journeys saved before `tripNumber` existed pick up the real train number here.
        if leg.line?.tripNumber == nil { leg.line?.tripNumber = trip.line?.tripNumber }
        // Ring lines (S41/S42) pass the same station several times per trip, so the stop is picked
        // by its planned time too — not just the first/last visit, which can be hours off.
        let startIndex = closestStop(in: trip.stopovers, at: leg.origin, plannedTime: leg.departure.planned, side: \.departure)
        if let startIndex {
            let start = trip.stopovers[startIndex]
            if let departure = start.departure { leg.departure = Self.keepingActual(departure, from: leg.departure) }
            if start.departurePlatform?.best != nil { leg.departurePlatform = start.departurePlatform }
            if start.departureCancelled { leg.cancelled = true }
        }
        let rest = trip.stopovers[((startIndex ?? -1) + 1)...]
        // A leg riding round a ring more than once has its destination after its own intermediate stops: a
        // visit of the destination before them (the first lap's) is not it, however close in name.
        let lastIntermediate = leg.stopovers.compactMap { $0.departure?.planned ?? $0.arrival?.planned }.max()
        if let endIndex = closestStop(in: rest, at: leg.destination, plannedTime: leg.arrival.planned, side: \.arrival),
           lastIntermediate.map({ (trip.stopovers[endIndex].arrival?.planned ?? .distantFuture) >= $0 }) ?? true {
            let end = trip.stopovers[endIndex]
            if let arrival = end.arrival { leg.arrival = Self.keepingActual(arrival, from: leg.arrival) }
            if end.arrivalPlatform?.best != nil { leg.arrivalPlatform = end.arrivalPlatform }
            if end.arrivalCancelled { leg.cancelled = true }
            // A journey leg's headsign is only where its own feed stops modelling the train (e.g.
            // "Hengelo" for a Berlin–Amsterdam ICE), while the trip runs through to the real end.
            // Only taken from a trip that covers the whole leg, so a trip cut short at a border can't
            // undo the direction of a leg merged across it.
            // Nor one DB's feed ends at a border ("Rzepin" for the EC 47 to Warszawa): its own end is no direction.
            if let direction = trip.direction, !direction.isEmpty, !TransitousProvider.mayEndAtBorder(trip) { leg.direction = direction }
        }
        // Keep the intermediate stops as current as the endpoints.
        for index in leg.stopovers.indices {
            let stop = leg.stopovers[index]
            guard let live = trip.stopovers.first(where: {
                $0.station.isSamePlace(as: stop.station)
                    && $0.arrival?.planned == stop.arrival?.planned && $0.departure?.planned == stop.departure?.planned
            }) else { continue }
            if let arrival = live.arrival { leg.stopovers[index].arrival = Self.keepingActual(arrival, from: stop.arrival) }
            if let departure = live.departure { leg.stopovers[index].departure = Self.keepingActual(departure, from: stop.departure) }
            if live.arrivalCancelled { leg.stopovers[index].arrivalCancelled = true }
            if live.departureCancelled { leg.stopovers[index].departureCancelled = true }
        }
        return leg
    }

    /// Journeys saved before `TimetablesClient.infersOnTime` carry DB's made-up "on time" for trains
    /// hours ahead (actual == planned), which `keepingActual` would keep forever. Dropped while the
    /// train is still that far off; a real live time comes back from the trip or DB below.
    static func droppingInferredOnTime(_ leg: Leg, now: Date) -> Leg {
        guard !TimetablesClient.infersOnTime(departing: leg.departure.planned, now: now) else { return leg }
        func dropped(_ time: TimeInfo?) -> TimeInfo? {
            guard var time, time.actual == time.planned else { return time }
            time.actual = nil
            return time
        }
        var leg = leg
        if let departure = dropped(leg.departure) { leg.departure = departure }
        if let arrival = dropped(leg.arrival) { leg.arrival = arrival }
        for index in leg.stopovers.indices {
            leg.stopovers[index].arrival = dropped(leg.stopovers[index].arrival)
            leg.stopovers[index].departure = dropped(leg.stopovers[index].departure)
        }
        return leg
    }

    /// `new`, but with `old`'s actual time when `new` has none for the same planned time: a trip
    /// without realtime (Transitous drops it some time after the train ran) mustn't wipe a delay
    /// already known.
    static func keepingActual(_ new: TimeInfo, from old: TimeInfo?) -> TimeInfo {
        guard new.actual == nil, let old, old.planned == new.planned else { return new }
        return old
    }

    /// Index of the visit to `station` whose planned `side` time is closest to `plannedTime`.
    static func closestStop(in stops: ArraySlice<Stopover>, at station: Station, plannedTime: Date,
                            side: KeyPath<Stopover, TimeInfo?>) -> Int? {
        stops.indices
            .filter { stops[$0].station.isSamePlace(as: station) }
            .min { distance(stops[$0], plannedTime, side) < distance(stops[$1], plannedTime, side) }
    }

    static func closestStop(in stops: [Stopover], at station: Station, plannedTime: Date,
                            side: KeyPath<Stopover, TimeInfo?>) -> Int? {
        closestStop(in: stops[...], at: station, plannedTime: plannedTime, side: side)
    }

    private static func distance(_ stop: Stopover, _ time: Date, _ side: KeyPath<Stopover, TimeInfo?>) -> TimeInterval {
        guard let planned = stop[keyPath: side]?.planned else { return .infinity }
        return abs(planned.timeIntervalSince(time))
    }

    static func apply(_ override: TimetablesLegOverride, to leg: Leg) -> Leg {
        var leg = leg
        if let departure = override.departure { leg.departure = departure }
        if let departurePlatform = override.departurePlatform { leg.departurePlatform = departurePlatform }
        if let arrival = override.arrival { leg.arrival = arrival }
        if let arrivalPlatform = override.arrivalPlatform { leg.arrivalPlatform = arrivalPlatform }
        // DB matched both ends running lifts a cancellation Transitous reported; `nil` leaves it be.
        if let cancelled = override.cancelled { leg.cancelled = cancelled }
        // Only what DB reports right now: an earlier refresh's notices may have been lifted since.
        leg.messages = override.messages
        return leg
    }
}
