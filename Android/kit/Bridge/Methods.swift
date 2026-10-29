// What the Android app can ask the Kit: one handler per method, JSON in and out. Kit models go to Kotlin as their
// own Codable JSON (dates as milliseconds since 1970) and come back the same way, so Kotlin can hand a station
// or journey back unchanged. What the iOS app computes from them (line names, colours, …) comes along precomputed
// (`Display.swift`), so the Android UI doesn't repeat Kit logic.
import BetterBahnKit
import Foundation

enum Methods {
    /// The app's provider, as on iOS (`AppModel.provider`): Transitous with bahn.de, bahn.expert, vagonweb.cz and
    /// bahn.jetzt for details. bahn.de answers only with Play Integrity (#467); until then those parts stay empty.
    static let provider = CombinedProvider()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    typealias Handler = @Sendable (Data) async throws -> Data

    /// `{"ok": result}`, or `{"error": message}` for an unknown method or a failed call.
    static func call(_ name: String, _ input: Data) async -> String {
        guard let handler = handlers[name] else { return failure("Unbekannte Methode \(name)") }
        do {
            let result = try await handler(input)
            return "{\"ok\":" + String(decoding: result, as: UTF8.self) + "}"
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static func failure(_ message: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func handler<Input: Decodable & Sendable, Output: Encodable>(
        _ body: @escaping @Sendable (Input) async throws -> Output
    ) -> Handler {
        { data in try StationNames.adding(to: encoder.encode(try await body(try decoder.decode(Input.self, from: data)))) }
    }

    private static let handlers: [String: Handler] = [
        "searchStations": handler(searchStations),
        "journeys": handler(journeys),
        "completeJourney": handler(completeJourney),
        "refreshJourney": handler(refreshJourney),
        "describeJourneys": handler(describeJourneys),
        "board": handler(board),
        "trip": handler(trip),
        "tripForLeg": handler(tripForLeg),
        "tripLeg": handler(tripLeg),
        "searchTrains": handler(searchTrains),
        "trainRun": handler(trainRun),
        "importShared": handler(importShared),
        "refreshSaved": handler(refreshSaved),
        "journeyExtras": handler(journeyExtras),
        "widgetState": handler(widgetState),
    ]

    // MARK: Stations

    struct SearchStations: Decodable, Sendable {
        /// What was typed, with the picker's shortcuts ("b", "t", "l", a flag; `StationSearch`).
        var text: String
    }

    /// The station picker's search. The user's location never leaves the device, and Android doesn't ask for it.
    @Sendable static func searchStations(_ input: SearchStations) async throws -> [Station] {
        let search = StationSearch(parsing: input.text)
        guard search.text.count >= 2 else { return [] }
        return search.filtered(try await provider.searchStations(search, near: nil))
    }

    // MARK: Connections

    struct Journeys: Decodable, Sendable {
        var from: Station
        var to: Station
        var date: Date
        var isArrival: Bool
        var cursor: String?
        var products: [Product]?
        var maxTransfers: Int?
        /// Stations to pass through, in order (`ViaRoutePlanner`): one search without paging, from `date`.
        var via: [ViaWaypoint]?
        /// Only connections this ticket covers ("Nur Deutschlandticket"); ones that just cross a border stay.
        var ticket: TicketType?
    }

    struct JourneysPage: Encodable {
        var journeys: [JourneyDisplay]
        var earlierCursor: String?
        var laterCursor: String?
        /// Dropped by the ticket filter.
        var hiddenCount = 0
    }

    /// The ticket filter for the chosen ticket (`AppModel.ticketFilter`, BahnCard 100 with DB's default rules).
    static func filter(for ticket: TicketType) -> TicketFilter {
        switch ticket {
        case .deutschlandticket: .deutschlandticket
        case .bahnCard100: .bahnCard100(.default)
        }
    }

    /// As in `JourneyResultsView`: connections the ticket doesn't cover go, unless they only cross a border; each
    /// kept one says whether the ticket covers it (the list shows those first).
    static func applying(_ ticket: TicketType?, to page: JourneysPage) -> JourneysPage {
        guard let ticket else { return page }
        let filter = filter(for: ticket)
        var page = page
        let before = page.journeys.count
        page.journeys = page.journeys.filter { filter.isValid($0.journey) || filter.crossesBorder($0.journey) }
        page.hiddenCount = before - page.journeys.count
        for index in page.journeys.indices { page.journeys[index].validWithTicket = filter.isValid(page.journeys[index].journey) }
        return page
    }

    /// One page of connections, as `JourneyResultsView.load(cursor:prepend:)` loads it (without ticket filters yet): bahn.de's train names where it answers within 1.5 s, duplicates dropped.
    @Sendable static func journeys(_ input: Journeys) async throws -> JourneysPage {
        let products = input.products.map { Product.upgradingLegacySelection(Set($0)) } ?? Set(Product.allCases)
        if let via = input.via, !via.isEmpty {
            let planner = ViaRoutePlanner(provider: provider, products: products)
            var found = try await planner.journeys(from: input.from, to: input.to, via: via, date: input.date)
            // Products apply per part already; only the overall transfer limit is left.
            if let maxTransfers = input.maxTransfers { found = found.filter { $0.transfers <= maxTransfers } }
            return applying(input.ticket, to: JourneysPage(journeys: found.removingDuplicateIDs().map(JourneyDisplay.init),
                                                           earlierCursor: nil, laterCursor: nil))
        }
        let page = try await provider.journeys(JourneyQuery(
            from: input.from, to: input.to, date: input.date, isArrival: input.isArrival, cursor: input.cursor,
            products: products, maxTransfers: input.maxTransfers))
        let corrected = await provider.correctingTrainNames(in: page.journeys, deadline: .milliseconds(1500))
        let journeys = corrected.removingDuplicateIDs().removingSameTrainDuplicates()
        return applying(input.ticket, to: JourneysPage(journeys: journeys.map(JourneyDisplay.init),
                                                       earlierCursor: page.earlierCursor, laterCursor: page.laterCursor))
    }

    struct JourneyInput: Decodable, Sendable {
        var journey: Journey
    }

    /// The journey with the stops and platforms its trains' feeds leave out (`JourneyDetailView`).
    @Sendable static func completeJourney(_ input: JourneyInput) async throws -> JourneyDisplay {
        JourneyDisplay(await provider.completingStopsAndPlatforms(of: input.journey, deadline: .seconds(4)))
    }

    /// Fresh times, platforms and cancellations for a saved journey (`JourneyRefresher`, as for "Reisen").
    @Sendable static func refreshJourney(_ input: JourneyInput) async throws -> JourneyDisplay {
        JourneyDisplay(await JourneyRefresher(provider: provider).refresh(input.journey))
    }

    struct JourneysInput: Decodable, Sendable {
        var journeys: [Journey]
    }

    /// Saved journeys as the app shows them, without asking any server.
    @Sendable static func describeJourneys(_ input: JourneysInput) async throws -> [JourneyDisplay] {
        input.journeys.map(JourneyDisplay.init)
    }

    // MARK: Departures and trains

    struct Board: Decodable, Sendable {
        var station: Station
        var kind: BoardKind
        var date: Date
        /// Minutes from `date`.
        var duration: Int
        var products: [Product]?
        var ticket: TicketType?
    }

    /// One window of a departure or arrival board.
    @Sendable static func board(_ input: Board) async throws -> [BoardEntryDisplay] {
        let products = input.products.map { Product.upgradingLegacySelection(Set($0)) } ?? Set(Product.allCases)
        let entries = try await provider.board(input.kind, at: input.station, date: input.date,
                                               duration: input.duration, products: products)
        // Sorted by live time, pass-throughs and trains ending here dropped (`StationBoardView`).
        return BoardFilter(products: products, ticketFilter: input.ticket.map(filter(for:))).apply(entries).map(BoardEntryDisplay.init)
    }

    struct TripInput: Decodable, Sendable {
        var id: String
        var source: DataSource
    }

    /// A train's whole run, from a board entry.
    @Sendable static func trip(_ input: TripInput) async throws -> TripDisplay {
        TripDisplay(try await provider.trip(id: input.id, source: input.source))
    }

    struct LegInput: Decodable, Sendable {
        var leg: Leg
    }

    /// The run of a journey's leg (also when the feed renumbered it since).
    @Sendable static func tripForLeg(_ input: LegInput) async throws -> TripDisplay {
        TripDisplay(try await provider.trip(for: input.leg))
    }

    struct TripLegInput: Decodable, Sendable {
        var trip: Trip
        var from: Int
        var to: Int
    }

    /// The ride on a train from one of its stops to a later one, as a journey to save (`TripView`'s selection).
    @Sendable static func tripLeg(_ input: TripLegInput) async throws -> JourneyDisplay {
        guard let leg = input.trip.leg(fromIndex: input.from, toIndex: input.to) else {
            throw TransitError.invalidInput("Zwischen diesen Halten fährt der Zug nicht.")
        }
        return JourneyDisplay(Journey(legs: [leg], source: input.trip.source))
    }

    // MARK: Train numbers

    struct SearchTrains: Decodable, Sendable {
        /// "ICE 123", "123"
        var text: String
        var date: Date
    }

    /// Runs with this number on the day, best match first (`TrainSearchOverlay`, via bahn.expert).
    @Sendable static func searchTrains(_ input: SearchTrains) async throws -> [TrainResult] {
        guard let query = TrainNumberQuery(input.text) else {
            throw TransitError.invalidInput("Gib eine Zugnummer ein, z. B. ICE 123.")
        }
        guard let finder = TrainNumberSearch(provider: provider) else { return [] }
        return try await finder.trains(query, on: input.date).map(TrainResult.init)
    }

    struct TrainRunInput: Decodable, Sendable {
        var result: TrainResult
    }

    struct TrainRun: Encodable {
        var entry: BoardEntryDisplay
        var trip: TripDisplay
    }

    /// The chosen run, as a board entry and its trip.
    @Sendable static func trainRun(_ input: TrainRunInput) async throws -> TrainRun {
        guard let finder = TrainNumberSearch(provider: provider) else { throw TransitError.notFound("Zug") }
        let run = try await finder.run(of: input.result.kit)
        return TrainRun(entry: BoardEntryDisplay(run.entry), trip: TripDisplay(run.trip))
    }

    // MARK: Shared connections

    struct SharedText: Decodable, Sendable {
        var text: String
    }

    /// A connection shared from DB Navigator (its text or link), found again in our sources (`DBShareImporter`,
    /// the share extension on iOS).
    @Sendable static func importShared(_ input: SharedText) async throws -> JourneyDisplay {
        JourneyDisplay(try await DBShareImporter(provider: provider).journey(fromShared: input.text))
    }

    // MARK: Saved journeys in the background

    struct RefreshSaved: Decodable, Sendable {
        var journey: Journey
        /// IDs of what the user was already told about this journey.
        var notified: [String]
    }

    struct Notification: Encodable {
        var id: String
        var title: String
        /// Lines of the text; `since` (a time to show as "(seit 14:05)") belongs after the first.
        var lines: [String]
        var since: Date?
        /// A connection that no longer works: louder.
        var urgent: Bool
    }

    struct RefreshedSaved: Encodable {
        var journey: JourneyDisplay
        var notifications: [Notification]
        var notified: [String]
    }

    /// Fresh live data for a saved journey and what's new to notify, as `AppModel.refresh(_:using:)` does on iOS:
    /// broken or tight transfers and cancelled trains, new delay reasons, platform changes within two hours.
    @Sendable static func refreshSaved(_ input: RefreshSaved) async throws -> RefreshedSaved {
        let previous = input.journey
        let refreshed = await JourneyRefresher(provider: provider).refresh(previous)
        let known = Set(input.notified)
        let route = [refreshed.legs.first?.origin.displayName, refreshed.legs.last?.destination.displayName]
            .compactMap { $0 }.joined(separator: " → ")
        var notifications: [Notification] = []

        for issue in refreshed.connectionIssues() where !known.contains(issue.id) {
            notifications.append(Notification(id: issue.id, title: issue.title, lines: [issue.message] + (route.isEmpty ? [] : [route]),
                                              since: nil, urgent: issue.isBlocking))
        }
        // New delay reasons from DB get a notification; plain notices only show as the warning sign.
        for leg in refreshed.transitLegs {
            for message in leg.messages where message.kind == .delay {
                let id = "reason|\(leg.id)|\(message.text)"
                guard !known.contains(id) else { continue }
                let line = leg.line?.name ?? "Zug"
                let delay = leg.departure.delayMinutes ?? 0
                notifications.append(Notification(
                    id: id, title: delay > 0 ? "\(line): +\(delay) Min." : "\(line): Verspätungsgrund",
                    lines: [message.text, "\(leg.origin.displayName) → \(leg.destination.displayName)"],
                    since: message.timestamp, urgent: false))
            }
        }
        for change in refreshed.platformChanges(since: previous) where !known.contains(change.id) {
            notifications.append(Notification(id: change.id, title: change.title, lines: change.message.components(separatedBy: "\n"),
                                              since: nil, urgent: change.isTight))
        }
        return RefreshedSaved(journey: JourneyDisplay(refreshed), notifications: notifications,
                              notified: Array(known.union(notifications.map(\.id))).sorted())
    }

    // MARK: Journey details

    struct ArrivalWeather: Encodable {
        /// "12°"
        var temperature: String
        /// "Leichter Regen"
        var condition: String
        var weatherCode: Int
        var isDay: Bool
    }

    struct JourneyExtras: Encodable {
        /// CO₂ saved compared to going by car, in kg (`CO2Comparison.savedComparedToCar`).
        var co2SavedKilograms: Double
        /// Per leg (index into the journey's legs), the weather where it arrives (`WeatherClient`, Open-Meteo).
        var arrivalWeather: [String: ArrivalWeather]
    }

    /// What `JourneyDetailView` shows besides the trains: the CO₂ comparison and the weather at each arrival.
    @Sendable static func journeyExtras(_ input: JourneyInput) async throws -> JourneyExtras {
        let journey = input.journey
        let co2 = CO2Comparison(legs: journey.transitLegs)
        let weather = await WeatherClient.shared.weather(for: journey)
        var arrivals: [String: ArrivalWeather] = [:]
        for (index, leg) in journey.legs.enumerated() {
            guard let forecast = weather.arrival(of: leg, in: journey)?.forecast else { continue }
            arrivals[String(index)] = ArrivalWeather(temperature: forecast.temperatureText, condition: forecast.conditionText,
                                                     weatherCode: forecast.weatherCode, isDay: forecast.isDay)
        }
        return JourneyExtras(co2SavedKilograms: co2.savedComparedToCar, arrivalWeather: arrivals)
    }

    // MARK: Widget

    struct WidgetStateDisplay: Encodable {
        /// beforeDeparture, riding, transfer, arrived
        var phase: String
        var trainName: String
        var product: Product
        var nextStopName: String
        var nextStopTime: Date
        var nextStopDelayMinutes: Int?
        var platform: String?
        var originName: String
        var destinationName: String
        var finalArrival: Date
        var finalDelayMinutes: Int?
        var cancelled: Bool
        var warning: String?
        /// At a transfer: where, the next train and its platform and departure.
        var transferStation: String?
        var transferTrain: String?
        var transferPlatform: String?
        var transferDeparture: Date?
    }

    /// What the "Reiseübersicht" widget shows now (`JourneyWidgetState`), for the next saved journey that isn't over.
    @Sendable static func widgetState(_ input: JourneysInput) async throws -> WidgetStateDisplay? {
        let now = Date.now
        let next = input.journeys.filter { !$0.isOver(now: now) }
            .min { ($0.departure?.planned ?? .distantFuture) < ($1.departure?.planned ?? .distantFuture) }
        guard let journey = next, let state = JourneyWidgetState.from(journey, now: now) else { return nil }
        let phase: String = switch state.phase {
        case .beforeDeparture: "beforeDeparture"
        case .riding: "riding"
        case .transfer: "transfer"
        case .arrived: "arrived"
        }
        return WidgetStateDisplay(
            phase: phase, trainName: state.trainName, product: state.product, nextStopName: state.nextStopName,
            nextStopTime: state.nextStopTime, nextStopDelayMinutes: state.nextStopDelayMinutes, platform: state.platform,
            originName: state.originName, destinationName: state.destinationName, finalArrival: state.finalArrival,
            finalDelayMinutes: state.finalDelayMinutes, cancelled: state.cancelled, warning: state.warning,
            transferStation: state.transfer?.station, transferTrain: state.transfer?.toTrain,
            transferPlatform: state.transfer?.toPlatform, transferDeparture: state.transfer?.departure)
    }
}
