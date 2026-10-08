import Foundation

public extension Leg {
    /// The timetable doesn't allow boarding where this leg starts or getting off where it ends
    /// ("Nur Ausstieg" / "Nur Einstieg").
    var breaksBoardingRules: Bool {
        stopovers.first?.access.allowsBoarding == false || stopovers.last?.access.allowsAlighting == false
    }
}

public extension Trip {
    /// Builds a leg riding this trip from `origin` to `destination`, if both are served in that order.
    func leg(from origin: Station, to destination: Station) -> Leg? {
        guard let startIndex = stopovers.firstIndex(where: { $0.station.isSamePlace(as: origin) }),
              let endIndex = stopovers[(startIndex + 1)...].firstIndex(where: { $0.station.isSamePlace(as: destination) })
        else { return nil }
        return leg(fromIndex: startIndex, toIndex: endIndex)
    }

    /// Builds a leg between two specific stops of this trip. Needed on ring lines (S41/S42), where
    /// the same station comes up more than once and picking it by station alone takes the wrong visit.
    func leg(fromIndex startIndex: Int, toIndex endIndex: Int) -> Leg? {
        guard stopovers.indices.contains(startIndex), stopovers.indices.contains(endIndex), startIndex < endIndex else { return nil }
        let start = stopovers[startIndex], end = stopovers[endIndex]
        guard let departure = start.departure, let arrival = end.arrival else { return nil }
        return Leg(
            origin: start.station, destination: end.station, departure: departure, arrival: arrival,
            departurePlatform: start.departurePlatform, arrivalPlatform: end.arrivalPlatform,
            tripId: id, line: line, direction: direction, isWalking: false,
            cancelled: cancelled || start.departureCancelled || end.arrivalCancelled,
            stopovers: Array(stopovers[startIndex...endIndex]), remarks: remarks, messages: messages, source: source
        )
    }
}

public extension Leg {
    /// The leg's own stops as a trip, for when its full run can't be loaded (any more): a past train
    /// Transitous has dropped, or no connection. Only what was saved, from where you got on to where you got off.
    var savedTrip: Trip? {
        guard !isWalking else { return nil }
        let stops = stopovers.count >= 2 ? stopovers : [
            Stopover(station: origin, arrival: nil, departure: departure, arrivalPlatform: nil,
                     departurePlatform: departurePlatform, cancelled: cancelled),
            Stopover(station: destination, arrival: arrival, departure: nil, arrivalPlatform: arrivalPlatform,
                     departurePlatform: nil, cancelled: cancelled),
        ]
        return Trip(id: tripId ?? id, line: line, direction: direction, stopovers: stops, cancelled: cancelled,
                    remarks: remarks, messages: messages, source: source)
    }
}

public extension Trip {
    /// This run with the Zusatzhalte `leg` remembered (bahn.de only reports them while the train runs),
    /// each put in by its planned time, unless the run already has that stop.
    func keepingAdditionalStops(of leg: Leg) -> Trip {
        func time(_ stop: Stopover) -> Date? { stop.arrival?.planned ?? stop.departure?.planned }
        var trip = self
        for extra in leg.stopovers where extra.isAdditional {
            guard let at = time(extra), !trip.stopovers.contains(where: { $0.station.isSamePlace(as: extra.station) }) else { continue }
            let index = trip.stopovers.firstIndex { stop in time(stop).map { $0 > at } ?? false } ?? trip.stopovers.endIndex
            trip.stopovers.insert(extra, at: index)
        }
        return trip
    }
}

/// Result of picking a specific train: the ride itself, plus – when boarding at the requested origin
/// or alighting at the requested destination isn't actually allowed on it – a rule-respecting
/// alternative between the same two stations.
public struct TrainMatch: Sendable {
    public var journey: Journey
    public var breaksBoardingRules: Bool
    public var alternative: Journey?
}

/// Result of `TrainPicker.replacing(legAt:in:with:finalDestination:)`: the new plan, and the planned
/// train after the new ones if it can no longer be caught.
public struct LegReplacement: Sendable, Hashable {
    public var journey: Journey
    public var missedConnection: MissedConnection?

    public init(journey: Journey, missedConnection: MissedConnection? = nil) {
        self.journey = journey
        self.missedConnection = missedConnection
    }
}

/// A planned train that leaves before the one before it arrives (same rule as
/// `Journey.connectionIssues`: under a minute to change counts as missed).
public struct MissedConnection: Sendable, Hashable {
    /// Index of the missed leg in `journey.legs`.
    public var legIndex: Int
    public var leg: Leg
    /// The train that arrives too late.
    public var arriving: Leg
    /// The earliest departure there that can still be caught.
    public var earliestDeparture: Date
}

public extension Leg {
    /// The earliest departure that can be caught after this leg arrives.
    var earliestConnection: Date { arrival.best.addingTimeInterval(TrainPicker.minimumTransfer) }

    /// Whether `next` can still be caught after this leg arrives.
    func catches(_ next: Leg) -> Bool { next.departure.best >= earliestConnection }
}

public extension Journey {
    /// Index of the next transit leg after the one at `index`.
    func nextTransitLegIndex(after index: Int) -> Int? {
        legs.indices.dropFirst(index + 1).first { !legs[$0].isWalking }
    }

    /// Where the leg at `index` could be rerouted to instead (see `TrainPicker.reroutes`): the index of
    /// the first later leg ending at a via or at `finalDestination`. Nil when the leg itself ends at one,
    /// since then there's no transfer point to skip.
    /// A via without a minimum stay can lie inside a through train's leg (`ViaRoutePlanner`); a reroute
    /// mustn't skip it, so it ends where that train is boarded, or isn't offered if that's `index` itself.
    func rerouteTargetIndex(from index: Int, vias: [Station], finalDestination: Station) -> Int? {
        guard legs.indices.contains(index) else { return nil }
        func isGoal(_ station: Station) -> Bool {
            station.isSamePlace(as: finalDestination) || vias.contains { station.isSamePlace(as: $0) }
        }
        func passesVia(_ leg: Leg) -> Bool {
            leg.stopovers.dropFirst().dropLast().contains { stop in vias.contains { stop.station.isSamePlace(as: $0) } }
        }
        guard !isGoal(legs[index].destination), !passesVia(legs[index]) else { return nil }
        let later = legs.indices.dropFirst(index + 1).filter { !legs[$0].isWalking }
        var previous = index
        for candidate in later {
            if passesVia(legs[candidate]) { return previous == index ? nil : previous }
            if isGoal(legs[candidate].destination) { return candidate }
            previous = candidate
        }
        // Without a goal among them (a walk to an address at the end), the last train's stop counts.
        return later.last
    }

    /// The next transit leg after the one at `index`, if it leaves too soon after that one arrives.
    func missedConnection(after index: Int) -> MissedConnection? {
        guard legs.indices.contains(index), !legs[index].isWalking,
              let nextIndex = nextTransitLegIndex(after: index) else { return nil }
        let arriving = legs[index], next = legs[nextIndex]
        guard !arriving.cancelled, !next.cancelled, !arriving.catches(next) else { return nil }
        return MissedConnection(legIndex: nextIndex, leg: next, arriving: arriving, earliestDeparture: arriving.earliestConnection)
    }
}

/// Lets the user force a specific train into a route (e.g. ICE 423 instead of the faster ICE 1).
public struct TrainPicker: Sendable {
    let provider: CombinedProvider
    let maxCandidates: Int
    /// Shortest change that still counts as caught, as in `Journey.connectionIssues` (1 min).
    static let minimumTransfer: TimeInterval = 60

    public init(provider: CombinedProvider, maxCandidates: Int = 25) {
        self.provider = provider
        self.maxCandidates = maxCandidates
    }

    /// Other trains that also go from `leg.origin` to `leg.destination` around the same time.
    /// With `notBefore` (a missed connection, see `MissedConnection`) only trains leaving then or later,
    /// in the window after that time.
    public func alternatives(for leg: Leg, minutesBefore: Int = 30, minutesAfter: Int = 180,
                             notBefore: Date? = nil, ticketFilter: TicketFilter? = nil) async throws -> [Leg] {
        let (start, end) = Self.window(for: leg, minutesBefore: minutesBefore, minutesAfter: minutesAfter, notBefore: notBefore)
        let entries = try await provider.departures(at: leg.origin, date: start,
                                                    duration: Int(end.timeIntervalSince(start) / 60))
        let candidates = entries
            .filter { $0.line.product.isTrain && $0.tripId != leg.tripId && !$0.cancelled }
            .filter { entry in notBefore.map { entry.time.best >= $0 } ?? true }
            .filter { ticketFilter?.isValid($0) ?? true }
            .sorted { Self.rank($0, like: leg) < Self.rank($1, like: leg) }
            .prefix(maxCandidates)
        let legs = await legs(for: Array(candidates), from: leg.origin, to: leg.destination)
        return legs.sorted { $0.departure.planned < $1.departure.planned }
    }

    /// The departure window to look for other trains in (planned times): around the leg's own departure,
    /// or around `notBefore` when that's later, so trains planned a bit earlier but running late enough
    /// still come up (the callers drop those actually leaving before `notBefore`).
    static func window(for leg: Leg, minutesBefore: Int, minutesAfter: Int, notBefore: Date?) -> (start: Date, end: Date) {
        let reference = max(leg.departure.planned, notBefore ?? .distantPast)
        return (reference.addingTimeInterval(TimeInterval(-minutesBefore * 60)),
                reference.addingTimeInterval(TimeInterval(minutesAfter * 60)))
    }

    /// Connections with transfers from `leg.origin` to `leg.destination` in the same time window, for
    /// when no other train goes there directly or changing trains is faster. Direct ones are left out:
    /// `alternatives(for:)` already lists them.
    public func connections(for leg: Leg, minutesBefore: Int = 30, minutesAfter: Int = 180,
                            notBefore: Date? = nil, ticketFilter: TicketFilter? = nil) async throws -> [Journey] {
        try await journeys(around: leg, to: leg.destination, minutesBefore: minutesBefore, minutesAfter: minutesAfter,
                           notBefore: notBefore, ticketFilter: ticketFilter)
            .filter { $0.transitLegs.count > 1 }
    }

    /// Connections from `leg.origin` straight on to `target` (the next via or the final destination,
    /// see `Journey.rerouteTargetIndex`) in the same time window that don't change trains where `leg`
    /// ends, e.g. a direct train skipping that transfer. Shown as "Andere Routenführung".
    public func reroutes(for leg: Leg, to target: Station, minutesBefore: Int = 30, minutesAfter: Int = 180,
                         notBefore: Date? = nil, ticketFilter: TicketFilter? = nil) async throws -> [Journey] {
        try await journeys(around: leg, to: target, minutesBefore: minutesBefore, minutesAfter: minutesAfter,
                           notBefore: notBefore, ticketFilter: ticketFilter)
            .filter { journey in !journey.transitLegs.dropLast().contains { $0.destination.isSamePlace(as: leg.destination) } }
            .sorted { ($0.arrival?.best ?? .distantFuture) < ($1.arrival?.best ?? .distantFuture) }
    }

    /// Journeys from `leg.origin` to `destination` leaving in `leg`'s window, by departure.
    private func journeys(around leg: Leg, to destination: Station, minutesBefore: Int, minutesAfter: Int,
                          notBefore: Date?, ticketFilter: TicketFilter?) async throws -> [Journey] {
        let (start, end) = Self.window(for: leg, minutesBefore: minutesBefore, minutesAfter: minutesAfter, notBefore: notBefore)
        var query = JourneyQuery(from: leg.origin, to: destination, date: start)
        var found: [Journey] = []
        // A page often covers only an hour or two; one more page fills the rest of the window.
        for _ in 0..<2 {
            let page = try await provider.journeys(query)
            found += page.journeys
            guard let cursor = page.laterCursor,
                  let last = page.journeys.compactMap(\.departure?.planned).max(), last < end else { break }
            query.cursor = cursor
        }
        var seen = Set<String>()
        return found
            .filter { journey in
                guard !journey.transitLegs.isEmpty, !journey.isCancelled,
                      let departure = journey.departure?.planned, departure >= start, departure <= end else { return false }
                if let notBefore, let best = journey.departure?.best, best < notBefore { return false }
                return ticketFilter?.isValid(journey) ?? true
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.departure?.planned ?? .distantFuture) < ($1.departure?.planned ?? .distantFuture) }
    }

    /// Finds a train by name (e.g. "ICE 423") departing `origin` within the next hours that reaches `destination`.
    /// Boarding/alighting restrictions ("Nur Einstieg" / "Nur Ausstieg") at either station are ignored when
    /// matching – the ride is built regardless – but flagged on the result, with a rule-respecting
    /// alternative looked up alongside it for anyone who'd rather not rely on it.
    public func journey(withTrain trainName: String, from origin: Station, to destination: Station,
                        date: Date, windowMinutes: Int = 240) async throws -> TrainMatch {
        let wanted = Line.normalize(trainName)
        guard !wanted.isEmpty else { throw TransitError.invalidInput("Bitte einen Zug angeben, z. B. „ICE 423“.") }
        let entries = try await provider.departures(at: origin, date: date, duration: windowMinutes)
        let matches = entries.filter { entry in
            // "ICE 423" matches the line name, "423" matches the train number alone.
            if Line.normalize(entry.line.name) == wanted { return true }
            return wanted.allSatisfy(\.isNumber) && entry.line.number == wanted
        }
        guard !matches.isEmpty else {
            throw TransitError.notFound("\(trainName) ab \(origin.name)")
        }
        let legs = await legs(for: matches, from: origin, to: destination)
        guard let leg = legs.min(by: { $0.departure.planned < $1.departure.planned }) else {
            throw TransitError.notFound("\(trainName) nach \(destination.name) (hält dort nicht)")
        }
        let breaksBoardingRules = leg.breaksBoardingRules
        var alternative: Journey?
        if breaksBoardingRules {
            alternative = try? await legalAlternative(from: origin, to: destination, date: leg.departure.planned)
        }
        return TrainMatch(journey: Journey(legs: [leg], source: leg.source),
                          breaksBoardingRules: breaksBoardingRules, alternative: alternative)
    }

    /// Direct trains from `origin` to `destination` the normal search leaves out because the timetable
    /// doesn't allow boarding at `origin` ("Nur Ausstieg", e.g. ICEs from Berlin Hbf to Gesundbrunnen)
    /// or getting off at `destination` ("Nur Einstieg"). Expert option: shown anyway, marked on the card.
    /// Candidates come from both stations' departure boards (`stationCalls`), so only those trains' runs are loaded.
    public func journeysIgnoringBoardingRules(from origin: Station, to destination: Station,
                                              calls: StationCalls) async -> [Journey] {
        let candidates = Self.restrictedCandidates(departures: calls.departuresAtOrigin, atDestination: calls.departuresAtDestination)
        let legs = await legs(for: candidates, from: origin, to: destination)
        return legs.filter(\.breaksBoardingRules)
            .sorted { $0.departure.planned < $1.departure.planned }
            .map { Journey(legs: [$0], source: $0.source) }
    }

    /// Departures at the origin that may not be boarded there, or whose train may not be left at the
    /// destination (it only lets passengers board there, so it shows as "Nur Einstieg" on that board).
    static func restrictedCandidates(departures: [BoardEntry], atDestination: [BoardEntry]) -> [BoardEntry] {
        let entryOnlyAtDestination = Set(atDestination.filter { $0.access == .entryOnly }.map(\.tripId))
        var seen = Set<String>()
        return departures.filter { entry in
            guard entry.line.product.isTrain, !entry.cancelled,
                  entry.access == .exitOnly || entryOnlyAtDestination.contains(entry.tripId) else { return false }
            return seen.insert(entry.tripId).inserted
        }
    }

    /// A normal connection between the same two stations, for when the picked train doesn't actually
    /// allow boarding/alighting at one of them.
    private func legalAlternative(from origin: Station, to destination: Station, date: Date) async throws -> Journey? {
        let page = try await provider.journeys(JourneyQuery(from: origin, to: destination, date: date))
        return page.journeys.first { !$0.isCancelled }
    }

    /// Replaces the leg at `index` (see the other `replacing`).
    public func replacing(legAt index: Int, in journey: Journey, with newLeg: Leg, finalDestination: Station) async throws -> LegReplacement {
        try await replacing(legAt: index, in: journey, with: [newLeg], finalDestination: finalDestination)
    }

    /// Replaces the leg at `index` with one leg (a direct train) or several (a connection with transfers).
    public func replacing(legAt index: Int, in journey: Journey, with newLegs: [Leg], finalDestination: Station) async throws -> LegReplacement {
        try await replacing(legsIn: index...index, in: journey, with: newLegs, finalDestination: finalDestination)
    }

    /// Replaces the legs in `range` (one, or several for an "Andere Routenführung" up to the next via).
    /// When the new legs end where the last replaced one did, the rest of the plan stays as it was (#226);
    /// if its next train can't be caught any more, the result says so (`missedConnection`) and the user
    /// decides. Otherwise everything after it is planned anew.
    public func replacing(legsIn range: ClosedRange<Int>, in journey: Journey, with newLegs: [Leg],
                          finalDestination: Station) async throws -> LegReplacement {
        guard let firstLeg = newLegs.first, let newLeg = newLegs.last,
              journey.legs.indices.contains(range.lowerBound), journey.legs.indices.contains(range.upperBound) else {
            throw TransitError.invalidInput("Keine Verbindung ausgewählt.")
        }
        var legs = Array(journey.legs.prefix(range.lowerBound))
        // Drop a walking leg right before the replaced leg if it no longer fits.
        if let last = legs.last, last.isWalking, !last.destination.isSamePlace(as: firstLeg.origin) { legs.removeLast() }
        legs += newLegs
        let following = Array(journey.legs.dropFirst(range.upperBound + 1))
        if !following.isEmpty, newLeg.destination.isSamePlace(as: journey.legs[range.upperBound].destination) {
            let kept = Journey(legs: legs + following, source: journey.source)
            return LegReplacement(journey: kept, missedConnection: kept.missedConnection(after: legs.count - 1))
        }
        if newLeg.destination.isSamePlace(as: finalDestination) {
            return LegReplacement(journey: Journey(legs: legs, source: journey.source))
        }
        let minTransfer: TimeInterval = 3 * 60
        let page = try await provider.journeys(JourneyQuery(
            from: newLeg.destination, to: finalDestination,
            date: newLeg.arrival.best.addingTimeInterval(minTransfer)
        ))
        guard let rest = page.journeys.first(where: {
            ($0.departure?.best ?? .distantPast) >= newLeg.arrival.best && !$0.isCancelled
        }) else {
            throw TransitError.notFound("Anschluss ab \(newLeg.destination.name)")
        }
        var restLegs = rest.legs
        // The replan often continues in the same train – merge instead of showing it twice.
        if let next = restLegs.first, let tripId = newLeg.tripId, next.tripId == tripId, next.source == newLeg.source {
            var merged = newLeg
            merged.destination = next.destination
            merged.arrival = next.arrival
            merged.arrivalPlatform = next.arrivalPlatform
            merged.stopovers = newLeg.stopovers + next.stopovers.dropFirst()
            legs[legs.count - 1] = merged
            restLegs.removeFirst()
        }
        return LegReplacement(journey: Journey(legs: legs + restLegs, source: journey.source))
    }

    private func legs(for entries: [BoardEntry], from origin: Station, to destination: Station) async -> [Leg] {
        await withTaskGroup(of: Leg?.self) { group in
            var iterator = entries.makeIterator()
            var running = 0
            var results: [Leg] = []
            func addNext() -> Bool {
                guard let entry = iterator.next() else { return false }
                group.addTask {
                    guard let trip = try? await provider.trip(id: entry.tripId, source: entry.source) else { return nil }
                    return trip.leg(from: origin, to: destination)
                }
                return true
            }
            // At most 4 parallel requests to stay within API rate limits.
            while running < 4, addNext() { running += 1 }
            while let result = await group.next() {
                if let result { results.append(result) }
                _ = addNext()
            }
            return results
        }
    }

    /// Lower is better: same product first, then closest departure time.
    static func rank(_ entry: BoardEntry, like leg: Leg) -> Double {
        let sameProduct = entry.line.product == leg.line?.product ? 0.0 : 100_000.0
        return sameProduct + abs(entry.time.planned.timeIntervalSince(leg.departure.planned))
    }
}
