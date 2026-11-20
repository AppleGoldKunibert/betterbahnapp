// What the connection search needs beyond one page of results, as `ConnectionsView` and `JourneyResultsView` do it on
// iOS: the live lines of saved journeys, train series, the later passes over the results (detours, missing
// platforms, late train names), each card's live check, and the trains picked by hand ("Zug vorgeben", #225).
import BetterBahnKit
import Foundation

extension Methods {
    // MARK: Saved journeys on the search page

    struct LiveStatusInput: Decodable, Sendable {
        var journey: Journey
        var now: Date
    }

    /// Where a saved journey stands (`JourneyLiveStatus`), as indices into `journey.legs` so the app formats the
    /// times itself.
    struct LiveStatusDisplay: Encodable {
        struct Transfer: Encodable {
            var nextIndex: Int
            var minutes: Int
            /// DB lets the next train wait (`TransferDisposition.waiting`): shown instead of the minutes.
            var waiting: Bool
            var waitingTitle: String?
            var isMissed: Bool
        }
        /// "departure", "riding" or "transfer".
        var step: String
        var legIndex: Int
        var previousIndex: Int?
        var nextTransfer: Transfer?
        var upcomingIndices: [Int]
    }

    /// Nil once the journey has arrived.
    @Sendable static func liveStatus(_ input: LiveStatusInput) async throws -> LiveStatusDisplay? {
        guard let status = JourneyLiveStatus.at(input.now, of: input.journey) else { return nil }
        let legs = input.journey.legs
        func index(_ leg: Leg) -> Int { legs.firstIndex(of: leg) ?? 0 }
        var display: LiveStatusDisplay
        switch status.step {
        case .departure(let leg): display = LiveStatusDisplay(step: "departure", legIndex: index(leg), upcomingIndices: [])
        case .riding(let leg): display = LiveStatusDisplay(step: "riding", legIndex: index(leg), upcomingIndices: [])
        case .transfer(let previous, let next):
            display = LiveStatusDisplay(step: "transfer", legIndex: index(next), previousIndex: index(previous), upcomingIndices: [])
        }
        if let transfer = status.nextTransfer {
            let waiting = transfer.disposition == .waiting
            display.nextTransfer = .init(nextIndex: index(transfer.next), minutes: transfer.minutes, waiting: waiting,
                                         waitingTitle: waiting ? TransferDisposition.waiting.title : nil,
                                         isMissed: transfer.isMissed)
        }
        display.upcomingIndices = status.upcomingLegs.map(index)
        return display
    }

    struct TrainSeriesInput: Decodable, Sendable {
        var legs: [Leg]
    }

    /// The series of each leg's train ("ICE 3", "IC 2 Twindexx"), else its line (`AppModel.trainSeries(of:)`):
    /// vagonweb.cz's plan, bahn.expert's live assignment around the day of the ride.
    @Sendable static func trainSeries(_ input: TrainSeriesInput) async throws -> [String] {
        var names: [String] = []
        for leg in input.legs {
            if let summary = await TrainTypes.shared.summary(for: leg) {
                names.append(summary)
            } else if let line = leg.line?.name {
                names.append(line)
            }
        }
        return names
    }

    // MARK: Results

    struct RefineInput: Decodable, Sendable {
        var journeys: [Journey]
        var from: Station
        var to: Station
        /// The window the results cover, for the trains calling at both ends.
        var start: Date
        var end: Date
        /// A via search keeps the changes back onto a train calling at the start: there they are wanted.
        var isVia: Bool
        var ticket: TicketType?
    }

    /// The passes `JourneyResultsView` makes once the results show: routes that change onto a train also calling at
    /// the start (or leave one also calling at the destination) go (`StationCalls`), missing platforms come from
    /// DB Timetables, and bahn.de's train names that came too late for the search rename the trains.
    @Sendable static func refineJourneys(_ input: RefineInput) async throws -> [JourneyDisplay] {
        var journeys = input.journeys
        if !input.isVia {
            let calls = await TrainPicker(provider: provider).stationCalls(from: input.from, to: input.to,
                                                                           start: input.start, end: input.end)
            journeys = journeys.filter { !calls.isDetour($0) }.map(calls.marking)
        }
        if let timetables = timetablesClient() {
            journeys = await withTaskGroup(of: (Int, Journey).self) { group in
                for (index, journey) in journeys.enumerated() where journey.transitLegs.contains(where: {
                    $0.departurePlatform?.best == nil || $0.arrivalPlatform?.best == nil
                }) {
                    group.addTask { (index, await timetables.fillMissingPlatforms(in: journey)) }
                }
                var filled = journeys
                for await (index, journey) in group { filled[index] = journey }
                return filled
            }
        }
        let corrected = await provider.correctingTrainNames(in: journeys, deadline: .seconds(20))
        journeys = BahnDeClient.takingTrainNames(from: corrected, into: journeys)
        return marked(journeys, ticket: input.ticket)
    }

    /// The live times of a result as it shows (`JourneyResultsView.checkLive`), so a missed transfer or a
    /// cancellation the search didn't know yet shows as "Nicht möglich"; nil when live data can't change it.
    @Sendable static func checkLive(_ input: JourneyInput) async throws -> JourneyDisplay? {
        guard JourneyRefresher.isWorthLiveCheck(input.journey) else { return nil }
        let live = await JourneyRefresher(provider: provider, timetables: timetablesClient()).refreshEnds(input.journey)
        return JourneyDisplay(live)
    }

    /// DB Timetables answers only with our server's token (Play Integrity), like `AppModel.timetablesClient` without
    /// App Attest.
    static func timetablesClient() -> TimetablesClient? {
        WorkerAuth.shared.accessToken() == nil ? nil : TimetablesClient()
    }

    /// Each journey says whether the ticket covers it, only crosses a border, or runs entirely abroad.
    static func marked(_ journeys: [Journey], ticket: TicketType?) -> [JourneyDisplay] {
        guard let ticket else { return journeys.map(JourneyDisplay.init) }
        let filter = filter(for: ticket)
        return journeys.map { journey in
            var display = JourneyDisplay(journey)
            display.validWithTicket = filter.isValid(journey)
            display.entirelyAbroad = filter.isEntirelyAbroad(journey)
            return display
        }
    }

    // MARK: "Zug vorgeben" (#225)

    struct TrainCandidatesInput: Decodable, Sendable {
        var text: String
        /// Where the train could be boarded, most likely first.
        var stations: [Station]
        var target: Station
        var date: Date
    }

    struct TrainCandidateDisplay: Encodable {
        var id: String
        var line: LineDisplay?
        var name: String
        var direction: String?
        var boarding: Stopover?
        var exit: Stopover?
        var isExact: Bool
        /// Handed back to `planTrainRoute` as is.
        var requirement: TrainRequirement?
    }

    /// The trains fitting what was typed on the boards of the route's stations (`TrainCandidateFinder`); the boards
    /// are loaded once and shared by every letter typed.
    @Sendable static func trainCandidates(_ input: TrainCandidatesInput) async throws -> [TrainCandidateDisplay] {
        let finder = await Finders.shared.finder(stations: input.stations, date: input.date)
        let candidates = await finder.routeCandidates(for: input.text, stations: input.stations, target: input.target,
                                                      date: input.date)
        return candidates.map { candidate in
            let trip = candidate.trip
            let requirement = candidate.boarding.map { boarding in
                TrainRequirement(trainName: trip.line?.name ?? input.text, boarding: boarding.station,
                                 exit: candidate.exit?.station, tripId: trip.id, tripSource: trip.source,
                                 departure: boarding.departure?.planned)
            }
            return TrainCandidateDisplay(id: candidate.id, line: trip.line.map(LineDisplay.init),
                                         name: trip.line?.name ?? input.text, direction: trip.direction,
                                         boarding: candidate.boarding, exit: candidate.exit, isExact: candidate.isExact,
                                         requirement: requirement)
        }
    }

    struct PlanTrainRouteInput: Decodable, Sendable {
        var requirements: [TrainRequirement]
        var from: Station
        var to: Station
        var date: Date
        var ticket: TicketType?
    }

    struct TrainRoutePlanDisplay: Encodable {
        var journeys: [JourneyDisplay]
        /// Per requirement id, the train's name as the provider spells it ("423" → "ICE 423").
        var resolvedNames: [String: String]
        var breaksBoardingRules: Bool
    }

    /// Routes riding every picked train (`TrainRoutePlanner`, as `JourneyResultsView.replan`); with the ticket filter
    /// the ones it covers, unless none is.
    @Sendable static func planTrainRoute(_ input: PlanTrainRouteInput) async throws -> TrainRoutePlanDisplay {
        let planner = TrainRoutePlanner(provider: provider, timetables: timetablesClient())
        let plan = try await planner.plan(input.requirements, from: input.from, to: input.to, date: input.date,
                                          pickedEarlier: TrainCandidateFinder.earlierWindow)
        var journeys = plan.journeys.removingDuplicateIDs()
        if let ticket = input.ticket {
            let valid = journeys.filter(filter(for: ticket).isValid)
            if !valid.isEmpty { journeys = valid }
        }
        return TrainRoutePlanDisplay(
            journeys: marked(journeys, ticket: input.ticket),
            resolvedNames: Dictionary(uniqueKeysWithValues: plan.resolvedNames.map { ($0.key.uuidString, $0.value) }),
            breaksBoardingRules: plan.breaksBoardingRules)
    }
}

/// One `TrainCandidateFinder` per route and time while the sheet is open, so its boards load once.
actor Finders {
    static let shared = Finders()
    private var key: String?
    private var current: TrainCandidateFinder?

    func finder(stations: [Station], date: Date) async -> TrainCandidateFinder {
        let key = stations.map(\.id).joined(separator: "|") + "@\(Int(date.timeIntervalSince1970 / 600))"
        if let current, key == self.key { return current }
        let finder = TrainCandidateFinder(provider: Methods.provider)
        self.key = key
        current = finder
        await finder.prefetch(stations: stations, date: date)
        return finder
    }
}

/// The train series per train and day, looked up once (`AppModel.trainType(for:on:)`).
actor TrainTypes {
    static let shared = TrainTypes()
    private var cache: [String: String?] = [:]

    func summary(for leg: Leg) async -> String? {
        guard let ref = BahnDeClient.trainReference(for: leg.line) else { return nil }
        let date = leg.departure.planned
        let day = BahnDeClient.berlinDay(date)
        let key = "\(ref.category) \(ref.number)|\(day)"
        if let cached = cache[key] { return cached }
        let provider = Methods.provider
        var lookup: TrainTypeLookup?
        if let vagonweb = provider.vagonweb {
            lookup = try? await vagonweb.trainType(category: ref.category, number: ref.number, on: date)
        }
        // vagonweb has only the plan; around the day of the ride bahn.expert names the units (ICE 3neo Redesign).
        if lookup?.hasUnitNumbers != true, abs(date.timeIntervalSinceNow) < 36 * 3600,
           let live = try? await provider.bahnExpert?.trainType(category: ref.category, number: ref.number, date: day),
           live.hasUnitNumbers || lookup == nil {
            lookup = live
        }
        let summary = lookup?.summary
        cache[key] = summary
        return summary
    }
}
