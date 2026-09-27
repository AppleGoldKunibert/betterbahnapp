import Foundation

/// "I want to ride this exact train, boarding here" – optionally also "and get off there".
/// Several of these can be active at once; the planner honours all of them in one route.
public struct TrainRequirement: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    /// As typed, e.g. "ICE 423" or just "423".
    public var trainName: String
    /// Where to board this train. Required.
    public var boarding: Station
    /// Where to leave it again. When `nil` the planner tries every stop after `boarding` and keeps
    /// whichever one gets to the destination fastest.
    public var exit: Station?

    public init(id: UUID = UUID(), trainName: String, boarding: Station, exit: Station? = nil) {
        self.id = id
        self.trainName = trainName
        self.boarding = boarding
        self.exit = exit
    }
}

public struct TrainRoutePlan: Sendable {
    /// Full routes from the search's origin to its destination, all of them riding every required
    /// train, fastest (earliest arrival) first.
    public var journeys: [Journey]
    /// Name as the provider spells it, per requirement – "423" typed in comes back as "ICE 423".
    public var resolvedNames: [UUID: String]
    /// The schedule doesn't allow boarding/alighting somewhere the user asked to ("Nur Einstieg" /
    /// "Nur Ausstieg"). The route is built anyway, but worth telling them about.
    public var breaksBoardingRules: Bool

    public var best: Journey? { journeys.first }
}

/// Builds a complete route that rides one or more user-chosen trains.
///
/// Per requirement it finds the next run of that train the traveller can actually reach, plans the
/// feeder connection so it arrives in time, and then continues from wherever the ride ends. If no
/// exit stop was named, every stop after boarding is tried and the one leading to the fastest
/// remaining route wins.
public struct TrainRoutePlanner: Sendable {
    public let provider: CombinedProvider
    /// DB's own dispatching plan, consulted when a named train can't be matched on `provider`'s own
    /// board – its coverage or branding can miss a train that genuinely exists. Optional: without
    /// credentials configured, the planner still works, just without that rescue.
    public let timetables: TimetablesClient?
    /// How many partial routes to carry from one requirement to the next.
    public var beamWidth: Int
    /// Upper bound on the stops tried when no exit station was given (keeps request counts sane).
    public var maxAlightCandidates: Int
    /// How many onward connections to branch into per alighting stop.
    public var branchFactor: Int
    /// How long to look for the named train, in minutes, per attempt (two attempts are made).
    public var windowMinutes: Int
    /// Minimum time between getting off one train and the next one departing.
    public var minTransfer: TimeInterval

    public init(provider: CombinedProvider, timetables: TimetablesClient? = nil, beamWidth: Int = 3,
                maxAlightCandidates: Int = 8, branchFactor: Int = 2, windowMinutes: Int = 480, minTransferMinutes: Int = 3) {
        self.provider = provider
        self.timetables = timetables
        self.beamWidth = beamWidth
        self.maxAlightCandidates = maxAlightCandidates
        self.branchFactor = branchFactor
        self.windowMinutes = windowMinutes
        self.minTransfer = TimeInterval(minTransferMinutes * 60)
    }

    /// A route built so far, ending at `station` at `time`.
    private struct Partial: Sendable {
        var legs: [Leg]
        var station: Station
        var time: Date
        var breaksRules: Bool
    }

    /// Plans routes from `from` to `to` that ride every requirement, in the order given.
    public func plan(_ requirements: [TrainRequirement], from: Station, to: Station,
                     date: Date, limit: Int = 5) async throws -> TrainRoutePlan {
        guard !requirements.isEmpty else {
            throw TransitError.invalidInput("Keine Zugvorgabe ausgewählt.")
        }
        var beam = [Partial(legs: [], station: from, time: date, breaksRules: false)]
        var names: [UUID: String] = [:]

        for (index, requirement) in requirements.enumerated() {
            // Without an exit stop the choice of where to get off depends on where we head next.
            let target = index + 1 < requirements.count ? requirements[index + 1].boarding : to
            var next: [Partial] = []
            var failure: Error?
            for partial in beam {
                do {
                    let (extended, name) = try await extend(partial, with: requirement, target: target)
                    next += extended
                    names[requirement.id] = name
                } catch {
                    if failure == nil { failure = error }
                }
            }
            guard !next.isEmpty else {
                throw failure ?? TransitError.notFound(requirement.trainName)
            }
            beam = prune(next)
        }

        var finished: [Partial] = []
        for partial in beam {
            finished += await completing(partial, to: to)
        }
        guard !finished.isEmpty else {
            throw TransitError.notFound("Anschluss nach \(to.displayName)")
        }
        let journeys = prune(finished, keeping: limit).map {
            Journey(legs: $0.legs, source: $0.legs.first?.source ?? provider.source)
        }
        return TrainRoutePlan(journeys: journeys, resolvedNames: names,
                              breaksBoardingRules: finished.contains(where: \.breaksRules))
    }

    // MARK: - One requirement

    private func extend(_ partial: Partial, with requirement: TrainRequirement,
                        target: Station) async throws -> ([Partial], String) {
        // 1. When does the traveller realistically stand at the boarding station?
        let needsFeeder = !partial.station.isSamePlace(as: requirement.boarding)
        var reachable: [Journey] = []
        var earliest = partial.time
        if needsFeeder {
            reachable = try await connections(from: partial.station, to: requirement.boarding, departingAfter: partial.time)
            guard let soonest = reachable.compactMap({ $0.arrival?.best }).min() else {
                throw TransitError.notFound("Verbindung nach \(requirement.boarding.displayName)")
            }
            earliest = soonest
        }

        // 2. The next run of the wanted train that can still be caught.
        let (entry, trip) = try await train(requirement.trainName, at: requirement.boarding,
                                            notBefore: earliest.addingTimeInterval(needsFeeder ? minTransfer : 0))
        guard let boardIndex = trip.stopovers.firstIndex(where: { $0.station.isSamePlace(as: requirement.boarding) }),
              let departure = trip.stopovers[boardIndex].departure
        else { throw TransitError.notFound("\(requirement.trainName) ab \(requirement.boarding.displayName)") }

        // 3. Ride to the boarding station as late as comfortably possible.
        var feederLegs: [Leg] = []
        if needsFeeder {
            guard let feeder = await feeder(from: partial.station, to: requirement.boarding,
                                            arriveBy: departure.best, notBefore: partial.time, fallbacks: reachable)
            else { throw TransitError.notFound("Verbindung nach \(requirement.boarding.displayName) bis \(departure.best.formatted(date: .omitted, time: .shortened))") }
            feederLegs = feeder.legs
        }

        // 4. Where to get off, and how to go on from there.
        let alightStations = requirement.exit.map { [$0] }
            ?? alightCandidates(trip: trip, after: boardIndex, target: target)
        let extended = await rides(trip: trip, from: requirement.boarding, to: alightStations,
                                   target: target, continuing: requirement.exit == nil,
                                   after: feederLegs, base: partial)
        guard !extended.isEmpty else {
            let where_ = requirement.exit?.displayName ?? target.displayName
            throw TransitError.notFound("\(entry.line.name) nach \(where_) (hält dort nicht)")
        }
        return (prune(extended), entry.line.name)
    }

    /// Builds one partial route per alighting stop (and, when continuing, per onward connection).
    private func rides(trip: Trip, from boarding: Station, to alightStations: [Station], target: Station,
                       continuing: Bool, after feederLegs: [Leg], base: Partial) async -> [Partial] {
        let legs = alightStations.compactMap { trip.leg(from: boarding, to: $0) }
        guard continuing else {
            return legs.map { ride in
                Partial(legs: merge(base.legs + feederLegs + [ride]), station: ride.destination,
                        time: ride.arrival.best, breaksRules: base.breaksRules || breaksRules(ride))
            }
        }
        let planner = self
        return await withTaskGroup(of: [Partial].self) { group in
            var iterator = legs.makeIterator()
            var running = 0
            var results: [Partial] = []
            func addNext() -> Bool {
                guard let ride = iterator.next() else { return false }
                group.addTask {
                    let broken = base.breaksRules || planner.breaksRules(ride)
                    if ride.destination.isSamePlace(as: target) {
                        return [Partial(legs: planner.merge(base.legs + feederLegs + [ride]), station: ride.destination,
                                        time: ride.arrival.best, breaksRules: broken)]
                    }
                    let onward = await planner.onward(from: ride, to: target)
                    return onward.map { option in
                        Partial(legs: planner.merge(base.legs + feederLegs + [ride] + option.legs), station: target,
                                time: option.arrival?.best ?? ride.arrival.best, breaksRules: broken)
                    }
                }
                return true
            }
            // At most 4 parallel requests to stay within API rate limits.
            while running < 4, addNext() { running += 1 }
            while let result = await group.next() {
                results += result
                _ = addNext()
            }
            return results
        }
    }

    private func onward(from ride: Leg, to target: Station) async -> [Journey] {
        let options = (try? await connections(from: ride.destination, to: target,
                                              departingAfter: ride.arrival.best.addingTimeInterval(minTransfer))) ?? []
        return Array(options.sorted { ($0.arrival?.best ?? .distantFuture) < ($1.arrival?.best ?? .distantFuture) }
            .prefix(branchFactor))
    }

    /// Finishes a route that still has to get from where the last ride ended to the destination.
    private func completing(_ partial: Partial, to destination: Station) async -> [Partial] {
        if partial.station.isSamePlace(as: destination) { return [partial] }
        let options = (try? await connections(from: partial.station, to: destination,
                                              departingAfter: partial.time.addingTimeInterval(minTransfer))) ?? []
        return options.sorted { ($0.arrival?.best ?? .distantFuture) < ($1.arrival?.best ?? .distantFuture) }
            .prefix(branchFactor)
            .map { option in
                Partial(legs: merge(partial.legs + option.legs), station: destination,
                        time: option.arrival?.best ?? partial.time, breaksRules: partial.breaksRules)
            }
    }

    // MARK: - Provider queries

    private func connections(from: Station, to: Station, departingAfter: Date) async throws -> [Journey] {
        let page = try await provider.journeys(JourneyQuery(from: from, to: to, date: departingAfter))
        return page.journeys.filter {
            !$0.isCancelled && $0.arrival != nil
                && ($0.departure?.best ?? .distantPast) >= departingAfter.addingTimeInterval(-60)
        }
    }

    /// The connection that reaches `to` before `arriveBy` and leaves as late as possible.
    private func feeder(from: Station, to: Station, arriveBy: Date, notBefore: Date,
                        fallbacks: [Journey]) async -> Journey? {
        var candidates: [Journey] = []
        if let page = try? await provider.journeys(JourneyQuery(from: from, to: to, date: arriveBy, isArrival: true)) {
            candidates = page.journeys
        }
        candidates += fallbacks
        let usable = candidates.filter {
            !$0.isCancelled
                && ($0.arrival?.best ?? .distantFuture) <= arriveBy
                && ($0.departure?.best ?? .distantPast) >= notBefore.addingTimeInterval(-60)
        }
        return usable.max { ($0.departure?.best ?? .distantPast) < ($1.departure?.best ?? .distantPast) }
    }

    /// Finds the next run of `name` leaving `station` at or after `notBefore`.
    private func train(_ name: String, at station: Station, notBefore: Date) async throws -> (BoardEntry, Trip) {
        let wanted = Line.normalize(name)
        guard !wanted.isEmpty else {
            throw TransitError.invalidInput("Bitte einen Zug angeben, z. B. „ICE 423“.")
        }
        let slack: TimeInterval = -2 * 60
        var windowStart = notBefore.addingTimeInterval(slack)
        // Two windows: a train named for a search in the evening may only run again next morning.
        for _ in 0..<2 {
            let entries = try await provider.departures(at: station, date: windowStart, duration: windowMinutes)
            var matches: [BoardEntry] = []
            for entry in entries.filter({ $0.time.best >= notBefore.addingTimeInterval(slack) && Self.matches(wanted, $0.line) })
                .sorted(by: { $0.time.best < $1.time.best }) {
                if entry.cancelled, !(await cancellationDisputed(entry, at: station)) { continue }
                matches.append(entry)
            }
            if matches.isEmpty {
                matches = await rescuedMatches(name: name, at: station, windowStart: windowStart, in: entries)
            }
            for match in matches {
                if let trip = try? await provider.trip(id: match.tripId, source: match.source) {
                    return (match, trip)
                }
            }
            windowStart = windowStart.addingTimeInterval(TimeInterval(windowMinutes * 60))
        }
        throw TransitError.notFound("\(name) ab \(station.displayName)")
    }

    /// The provider's board says `entry` is cancelled – that is sometimes wrong (stale or mismatched
    /// realtime), so ask DB's own dispatching feed. Only when it explicitly reports the departure as
    /// not cancelled is the entry kept; if it can't tell, the provider's verdict stands.
    private func cancellationDisputed(_ entry: BoardEntry, at station: Station) async -> Bool {
        guard let timetables, let number = entry.line.dispatchNumber,
              let category = TimetablesClient.category(from: entry.line.name) else { return false }
        return await timetables.departureCancelled(category: category, number: number, at: station,
                                                   plannedTime: entry.time.planned) == false
    }

    /// When nothing in `entries` matched by name, asks DB's own dispatching plan (`TimetablesClient`)
    /// for the train's real scheduled time – its board can brand a train differently (e.g. an ÖBB "RJ"
    /// that DB calls "ICE") or simply not carry it at all – and treats whichever board entry departs
    /// closest to that confirmed time as it, so its trip can still be built from `provider`, which
    /// already has this station resolved (DB's own plan has no journey/trip data of its own).
    private func rescuedMatches(name: String, at station: Station, windowStart: Date, in entries: [BoardEntry]) async -> [BoardEntry] {
        guard let timetables, let parsed = Self.parseCategoryAndNumber(name) else { return [] }
        let times = await timetables.scheduledTimes(category: parsed.category, number: parsed.number, at: station,
                                                     from: windowStart, duration: windowMinutes)
        guard !times.isEmpty else { return [] }
        let tolerance: TimeInterval = 2 * 60
        let candidates = entries.filter { !$0.cancelled }
        var rescued: [BoardEntry] = []
        for time in times {
            guard let closest = candidates.min(by: { abs($0.time.best.timeIntervalSince(time)) < abs($1.time.best.timeIntervalSince(time)) }),
                  abs(closest.time.best.timeIntervalSince(time)) <= tolerance
            else { continue }
            rescued.append(closest)
        }
        return rescued
    }

    /// "ICE 423" matches the line name, "423" the train number alone.
    static func matches(_ wanted: String, _ line: Line) -> Bool {
        if Line.normalize(line.name) == wanted { return true }
        if let alternate = line.alternateName, Line.normalize(alternate) == wanted { return true }
        return wanted.allSatisfy(\.isNumber) && line.number == wanted
    }

    /// "ICE 423" -> ("ICE", "423"); "423" -> (nil, "423"); "ICE" alone -> nil (no number to look up).
    static func parseCategoryAndNumber(_ name: String) -> (category: String?, number: String)? {
        let tokens = name.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard let last = tokens.last, !last.isEmpty, last.allSatisfy(\.isNumber) else { return nil }
        let category = tokens.count > 1 ? tokens.dropLast().joined(separator: " ") : nil
        return (category, last)
    }

    // MARK: - Helpers

    /// Stops worth considering when the user didn't name one: the target itself if the train serves
    /// it, then the stops closest to the target – getting off far away from it rarely pays off.
    func alightCandidates(trip: Trip, after boardIndex: Int, target: Station) -> [Station] {
        var rest = trip.stopovers[(boardIndex + 1)...]
            .filter { !$0.arrivalCancelled && $0.access.allowsAlighting && $0.arrival != nil }
            .map(\.station)
        var head: [Station] = []
        if let index = rest.firstIndex(where: { $0.isSamePlace(as: target) }) {
            head = [rest.remove(at: index)]
        }
        let slots = max(0, maxAlightCandidates - head.count)
        if rest.count > slots {
            if let goal = target.coordinate {
                rest.sort {
                    ($0.coordinate?.distance(to: goal) ?? .greatestFiniteMagnitude)
                        < ($1.coordinate?.distance(to: goal) ?? .greatestFiniteMagnitude)
                }
            }
            rest = Array(rest.prefix(slots))
        }
        return head + rest
    }

    private func breaksRules(_ ride: Leg) -> Bool {
        ride.stopovers.first?.access.allowsBoarding == false || ride.stopovers.last?.access.allowsAlighting == false
    }

    /// Fastest first, duplicates dropped.
    private func prune(_ partials: [Partial], keeping limit: Int? = nil) -> [Partial] {
        var seen = Set<String>()
        let unique = partials
            .sorted { $0.time < $1.time }
            .filter { seen.insert($0.legs.map(\.id).joined(separator: "|")).inserted }
        return Array(unique.prefix(limit ?? beamWidth))
    }

    /// A replanned tail often continues in the same train – merge instead of showing it twice.
    func merge(_ legs: [Leg]) -> [Leg] {
        var result: [Leg] = []
        for leg in legs {
            guard var last = result.last, let tripId = last.tripId, !last.isWalking, !leg.isWalking,
                  leg.tripId == tripId, leg.source == last.source
            else {
                result.append(leg)
                continue
            }
            last.destination = leg.destination
            last.arrival = leg.arrival
            last.arrivalPlatform = leg.arrivalPlatform
            last.stopovers += leg.stopovers.dropFirst()
            last.cancelled = last.cancelled || leg.cancelled
            result[result.count - 1] = last
        }
        return result
    }
}
