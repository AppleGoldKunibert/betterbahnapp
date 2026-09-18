import Foundation

public extension Trip {
    /// Builds a leg riding this trip from `origin` to `destination`, if both are served in that order.
    func leg(from origin: Station, to destination: Station) -> Leg? {
        guard let startIndex = stopovers.firstIndex(where: { $0.station.isSamePlace(as: origin) }),
              let endIndex = stopovers[(startIndex + 1)...].firstIndex(where: { $0.station.isSamePlace(as: destination) })
        else { return nil }
        let start = stopovers[startIndex], end = stopovers[endIndex]
        guard let departure = start.departure, let arrival = end.arrival else { return nil }
        return Leg(
            origin: start.station, destination: end.station, departure: departure, arrival: arrival,
            departurePlatform: start.departurePlatform, arrivalPlatform: end.arrivalPlatform,
            tripId: id, line: line, direction: direction, isWalking: false,
            cancelled: cancelled || start.cancelled || end.cancelled,
            stopovers: Array(stopovers[startIndex...endIndex]), remarks: remarks, source: source
        )
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
                             bc100Rules: BC100Rules? = nil) async throws -> [Leg] {
        let start = leg.departure.planned.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        let entries = try await provider.departures(at: leg.origin, date: start, duration: minutesBefore + minutesAfter)
        let candidates = entries
            .filter { $0.line.product.isTrain && $0.tripId != leg.tripId && !$0.cancelled }
            .filter { bc100Rules?.isValid($0) ?? true }
            .sorted { Self.rank($0, like: leg) < Self.rank($1, like: leg) }
            .prefix(maxCandidates)
        let legs = await legs(for: Array(candidates), from: leg.origin, to: leg.destination)
        return legs.sorted { $0.departure.planned < $1.departure.planned }
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
        var legs = Array(journey.legs.prefix(index))
        // Drop a walking leg right before the replaced leg if it no longer fits.
        if let last = legs.last, last.isWalking, !last.destination.isSamePlace(as: newLeg.origin) { legs.removeLast() }
        legs.append(newLeg)
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
