import Foundation

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

/// Lets the user force a specific train into a route (e.g. ICE 423 instead of the faster ICE 1).
public struct TrainPicker: Sendable {
    let provider: CombinedProvider
    let maxCandidates: Int

    public init(provider: CombinedProvider, maxCandidates: Int = 25) {
        self.provider = provider
        self.maxCandidates = maxCandidates
    }

    /// Other trains that also go from `leg.origin` to `leg.destination` around the same time.
    public func alternatives(for leg: Leg, minutesBefore: Int = 30, minutesAfter: Int = 180,
                             ticketFilter: TicketFilter? = nil) async throws -> [Leg] {
        let start = leg.departure.planned.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        let entries = try await provider.departures(at: leg.origin, date: start, duration: minutesBefore + minutesAfter)
        let candidates = entries
            .filter { $0.line.product.isTrain && $0.tripId != leg.tripId && !$0.cancelled }
            .filter { ticketFilter?.isValid($0) ?? true }
            .sorted { Self.rank($0, like: leg) < Self.rank($1, like: leg) }
            .prefix(maxCandidates)
        let legs = await legs(for: Array(candidates), from: leg.origin, to: leg.destination)
        return legs.sorted { $0.departure.planned < $1.departure.planned }
    }

    /// Connections with transfers from `leg.origin` to `leg.destination` in the same time window, for
    /// when no other train goes there directly or changing trains is faster. Direct ones are left out:
    /// `alternatives(for:)` already lists them.
    public func connections(for leg: Leg, minutesBefore: Int = 30, minutesAfter: Int = 180,
                            ticketFilter: TicketFilter? = nil) async throws -> [Journey] {
        let start = leg.departure.planned.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        let end = leg.departure.planned.addingTimeInterval(TimeInterval(minutesAfter * 60))
        var query = JourneyQuery(from: leg.origin, to: leg.destination, date: start)
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
                guard journey.transitLegs.count > 1, !journey.isCancelled,
                      let departure = journey.departure?.planned, departure >= start, departure <= end else { return false }
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
        let breaksBoardingRules = leg.stopovers.first?.access.allowsBoarding == false
            || leg.stopovers.last?.access.allowsAlighting == false
        var alternative: Journey?
        if breaksBoardingRules {
            alternative = try? await legalAlternative(from: origin, to: destination, date: leg.departure.planned)
        }
        return TrainMatch(journey: Journey(legs: [leg], source: leg.source),
                          breaksBoardingRules: breaksBoardingRules, alternative: alternative)
    }

    /// A normal connection between the same two stations, for when the picked train doesn't actually
    /// allow boarding/alighting at one of them.
    private func legalAlternative(from origin: Station, to destination: Station, date: Date) async throws -> Journey? {
        let page = try await provider.journeys(JourneyQuery(from: origin, to: destination, date: date))
        return page.journeys.first { !$0.isCancelled }
    }

    /// Replaces the leg at `index` and replans everything after it.
    public func replacing(legAt index: Int, in journey: Journey, with newLeg: Leg, finalDestination: Station) async throws -> Journey {
        try await replacing(legAt: index, in: journey, with: [newLeg], finalDestination: finalDestination)
    }

    /// Replaces the leg at `index` with several legs (a connection with transfers) and replans everything after it.
    public func replacing(legAt index: Int, in journey: Journey, with newLegs: [Leg], finalDestination: Station) async throws -> Journey {
        guard let firstLeg = newLegs.first, let newLeg = newLegs.last else {
            throw TransitError.invalidInput("Keine Verbindung ausgewählt.")
        }
        var legs = Array(journey.legs.prefix(index))
        // Drop a walking leg right before the replaced leg if it no longer fits.
        if let last = legs.last, last.isWalking, !last.destination.isSamePlace(as: firstLeg.origin) { legs.removeLast() }
        legs += newLegs
        if newLeg.destination.isSamePlace(as: finalDestination) {
            return Journey(legs: legs, source: journey.source)
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
        return Journey(legs: legs + restLegs, source: journey.source)
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
