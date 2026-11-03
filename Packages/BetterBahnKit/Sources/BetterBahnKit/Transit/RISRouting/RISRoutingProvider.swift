import Foundation

/// Journeys from DB's own routing (RIS::Routing, DB's HAFAS behind it), as the "Verkehrslage" page on
/// bahnhof.de asks it: no key, undocumented, so only the fallback for when Transitous fails
/// (`CombinedProvider.fallback`). Compared on the same routes (Nov 2026), long-distance trains in Germany
/// matched Transitous exactly; RIS named trains abroad as DB does ("RJ 385", where Transitous says
/// "ICE 385") and gave a few more connections per page, but knows only stops with an EVA number (no
/// addresses, no FlixBus) and gives no positions for the stops in between.
///
/// Its legs' journey IDs are bahn.de's (`reiseloesung/fahrt`), so journeys and trips carry the source
/// `.bahnDe`, stations their EVA number as ID, and a trip comes from bahn.de through our server.
/// Stations are searched at bahn.de too. There is no board: bahn.de's carries too little for one.
public struct RISRoutingProvider: TransitProvider {
    public static let baseURL = URL(string: "https://verkehrslage.bahnhof.de/api/routing/")!
    /// RIS::Routing's own limit on the website; more transfers aren't searched.
    static let maxChanges = 5

    public var source: DataSource { .bahnDe }
    let http: HTTPClient
    let bahnDe: BahnDeClient

    public init(http: HTTPClient = HTTPClient(timeout: 10), bahnDe: BahnDeClient = BahnDeClient()) {
        self.http = http
        self.bahnDe = bahnDe
    }

    // MARK: Stations

    public func searchStations(_ query: String) async throws -> [Station] {
        try await bahnDe.searchStations(query)
    }

    // MARK: Journeys

    public func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        async let from = eva(for: query.from)
        async let to = eva(for: query.to)
        let body = try Self.requestBody(query, from: await from, to: await to)
        var request = URLRequest(url: Self.baseURL.appending(path: "multimodal"), timeoutInterval: http.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let response = try await http.send(request, as: Response.self)
        return Self.page(from: response)
    }

    /// The station's EVA number (HAFAS ID; bus and tram stops have one too): its own, the offline list's,
    /// else bahn.de's search.
    func eva(for station: Station) async throws -> String {
        if station.source == .bahnDe, station.id.allSatisfy(\.isNumber) { return station.id }
        guard let eva = try await bahnDe.evaNumber(for: station) else {
            throw TransitError.notFound(station.displayName)
        }
        return eva
    }

    static func requestBody(_ query: JourneyQuery, from: String, to: String) -> [String: Any] {
        var body: [String: Any] = [
            "origin": ["evaNumber": from, "type": "STOP_PLACE"],
            "destination": ["evaNumber": to, "type": "STOP_PLACE"],
            "navigationContext": query.cursor ?? "",
            "maxChanges": min(query.maxTransfers ?? maxChanges, maxChanges),
            "includeViaStops": true,
            "includePolyLines": false,
            "matchIDs": true,
            "provider": "HAFAS",
            "persona": "OCCASIONAL_TRAVELLER",
        ]
        body[query.isArrival ? "arrivalTime" : "departureTime"] = timeFormat.format(query.date)
        if query.products != Set(Product.allCases) {
            body["filterTransports"] = transportTypes(for: query.products)
        }
        return body
    }

    static let timeFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// RIS' transport types for `products`, each once, in a fixed order.
    static func transportTypes(for products: Set<Product>) -> [String] {
        var types: [String] = []
        for product in Product.allCases where products.contains(product) {
            for type in transportTypes(for: product) where !types.contains(type) { types.append(type) }
        }
        return types
    }

    static func transportTypes(for product: Product) -> [String] {
        switch product {
        case .highSpeed: ["HIGH_SPEED_TRAIN"]
        case .longDistance, .nightTrain: ["INTERCITY_TRAIN"]
        case .interregio: ["INTER_REGIONAL_TRAIN"]
        case .regionalExpress, .regional: ["REGIONAL_TRAIN"]
        case .suburban: ["CITY_TRAIN"]
        case .subway: ["SUBWAY"]
        case .tram: ["TRAM"]
        case .bus, .coach: ["BUS"]
        case .ferry: ["FERRY"]
        case .other: ["SHUTTLE"]
        }
    }

    // MARK: Trips

    /// The train's run from bahn.de's journey details (through our server): `id` is bahn.de's journey ID.
    public func trip(id: String) async throws -> Trip {
        let details = try await bahnDe.get(BahnDeClient.journeyURL(id), as: BahnDeClient.JourneyDetails.self)
        return Self.trip(id: id, from: details)
    }

    static func trip(id: String, from details: BahnDeClient.JourneyDetails) -> Trip {
        let stops = details.halte.compactMap(JourneyStop.init)
        let stopovers = stops.map { stop in
            Stopover(station: station(eva: stop.evaNumber, name: stop.name, coordinate: stop.coordinate),
                     arrival: stop.arrival, departure: stop.departure,
                     arrivalPlatform: stop.arrivalPlatform, departurePlatform: stop.departurePlatform,
                     cancelled: stop.isCancelled, isAdditional: stop.isAdditional)
        }
        let name = details.zugName.map(collapsingSpaces)
        let line = name.map { name in
            Line(name: name, number: BahnDeClient.trainNumber(in: name),
                 product: product(type: nil, category: details.halte.first?.kategorie, name: name), operatorName: nil)
        }
        return Trip(id: id, line: line, direction: stops.last?.name, stopovers: stopovers,
                    cancelled: !stopovers.isEmpty && stopovers.allSatisfy(\.cancelled), remarks: [], source: .bahnDe)
    }

    public func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] {
        throw TransitError.notFound(String(kit: "Abfahrtstafel"))
    }

    // MARK: Wire types

    struct Response: Decodable {
        var trips: [TripResult]?
        var navigationContextEarlier: String?
        var navigationContextLater: String?
    }

    struct TripResult: Decodable {
        var legs: [LegResult]
    }

    struct LegResult: Decodable {
        /// "JOURNEY" (a train or bus) or "WALK".
        var type: String
        var extJourneyID: String?
        var departure: Event?
        var arrival: Event?
        var via: [Via]?
        var canceled: Bool?
        // A walk's ends and times.
        var origin: Place?
        var destination: Place?
        var departureTime: Date?
        var arrivalTime: Date?
    }

    struct Place: Decodable {
        var stopPlaceID: String?
        var name: String?
    }

    struct StopPlace: Decodable {
        var evaNumber: String
        var name: String
    }

    struct Message: Decodable { var type: String?; var text: String? }

    struct Transport: Decodable {
        /// e.g. "HIGH_SPEED_TRAIN", "REGIONAL_TRAIN", "CITY_TRAIN", "BUS".
        var type: String?
        /// "ICE 1005", "S5", "Bus X35"; a regional train's is only its run number ("29542").
        var journeyDescription: String?
        /// "ICE", "S", or the operator's brand for a regional train ("vlx").
        var category: String?
        var number: Int?
        /// The line: "RE2", "S5", for an ICE its line number ("29").
        var line: String?
        /// What the website shows for a regional train, e.g. "RE2".
        var label: String?
        var direction: Direction?
        struct Direction: Decodable { var text: String? }
    }

    struct Administration: Decodable { var operatorName: String? }

    /// A leg's start or end.
    struct Event: Decodable {
        var stopPlace: StopPlace
        var timeSchedule: Date
        var time: Date?
        /// "SCHEDULE" (no live data), "PREVIEW" or "REAL".
        var timeType: String?
        var platform: String?
        var platformSchedule: String?
        var canceled: Bool?
        var messages: [Message]?
        var transport: Transport?
        var administration: Administration?
        /// HAFAS location ID with the position, "A=1@O=Berlin Hbf@X=13369549@Y=52525589@…".
        var extOriginID: String?
        var extDestinationID: String?
    }

    /// A stop between a leg's ends.
    struct Via: Decodable {
        var evaNumber: String
        var name: String
        var arrival: ViaEvent?
        var departure: ViaEvent?
    }

    struct ViaEvent: Decodable {
        var timeSchedule: Date
        var time: Date?
        var timeType: String?
        var platform: String?
        var platformSchedule: String?
        var canceled: Bool?
        var messages: [Message]?
    }

    // MARK: Mapping

    static func page(from response: Response) -> JourneyPage {
        JourneyPage(journeys: (response.trips ?? []).compactMap(journey), earlierCursor: response.navigationContextEarlier.nonEmpty,
                    laterCursor: response.navigationContextLater.nonEmpty, source: .bahnDe)
    }

    static func journey(_ trip: TripResult) -> Journey? {
        var legs: [Leg] = []
        for (index, result) in trip.legs.enumerated() {
            if result.type == "WALK" {
                if let walk = walk(result, before: trip.legs.dropFirst(index + 1).first, after: legs.last) { legs.append(walk) }
            } else if let leg = leg(result) {
                legs.append(leg)
            }
        }
        return legs.contains { !$0.isWalking } ? Journey(legs: legs, source: .bahnDe) : nil
    }

    static func leg(_ result: LegResult) -> Leg? {
        guard let departure = result.departure, let arrival = result.arrival else { return nil }
        let transport = departure.transport ?? arrival.transport
        let origin = station(departure.stopPlace, hafasID: departure.extOriginID)
        let destination = station(arrival.stopPlace, hafasID: arrival.extDestinationID)
        let line = transport.map { self.line($0, operatorName: departure.administration?.operatorName) }
        let vias = (result.via ?? []).map(stopover)
        let first = Stopover(station: origin, arrival: nil, departure: time(departure), arrivalPlatform: nil,
                             departurePlatform: platform(departure.platformSchedule, departure.platform),
                             cancelled: departure.canceled == true, access: access(departure.messages))
        let last = Stopover(station: destination, arrival: time(arrival), departure: nil,
                            arrivalPlatform: platform(arrival.platformSchedule, arrival.platform), departurePlatform: nil,
                            cancelled: arrival.canceled == true, access: access(arrival.messages))
        let remarks = unique(((departure.messages ?? []) + (arrival.messages ?? [])).compactMap(\.text).filter { access([$0]) == .normal })
        return Leg(origin: origin, destination: destination, departure: time(departure), arrival: time(arrival),
                   departurePlatform: first.departurePlatform, arrivalPlatform: last.arrivalPlatform,
                   tripId: result.extJourneyID, line: line, direction: transport?.direction?.text,
                   isWalking: false, cancelled: result.canceled == true || departure.canceled == true || arrival.canceled == true,
                   stopovers: [first] + vias + [last], remarks: remarks, source: .bahnDe)
    }

    /// A walk between two stops, with the stations of the legs around it (which have positions).
    static func walk(_ result: LegResult, before next: LegResult?, after previous: Leg?) -> Leg? {
        guard let start = result.departureTime, let end = result.arrivalTime else { return nil }
        let from = previous?.destination
            ?? result.origin.flatMap { place in place.stopPlaceID.map { station(eva: $0, name: place.name ?? $0, coordinate: nil) } }
        let to = next?.departure.map { station($0.stopPlace, hafasID: $0.extOriginID) }
            ?? result.destination.flatMap { place in place.stopPlaceID.map { station(eva: $0, name: place.name ?? $0, coordinate: nil) } }
        guard let from, let to else { return nil }
        return Leg(origin: from, destination: to, departure: TimeInfo(planned: start, actual: nil),
                   arrival: TimeInfo(planned: end, actual: nil), departurePlatform: nil, arrivalPlatform: nil, tripId: nil,
                   line: nil, direction: nil, isWalking: true, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    static func stopover(_ via: Via) -> Stopover {
        let messages = (via.arrival?.messages ?? []) + (via.departure?.messages ?? [])
        var stopover = Stopover(station: station(eva: via.evaNumber, name: via.name, coordinate: nil),
                                arrival: via.arrival.map(time), departure: via.departure.map(time),
                                arrivalPlatform: via.arrival.flatMap { platform($0.platformSchedule, $0.platform) },
                                departurePlatform: via.departure.flatMap { platform($0.platformSchedule, $0.platform) },
                                cancelled: false, access: access(messages))
        stopover.arrivalCancelled = via.arrival?.canceled == true
        stopover.departureCancelled = via.departure?.canceled == true
        return stopover
    }

    /// Named like Transitous names the same train, so both read alike: "ICE 1005" (number 1005), a regional
    /// train by its line with the run in brackets, "RE2 (29542)" (number 29542, as DELFI writes it), "S5"
    /// (number 5, run 5101), "Bus X35".
    static func line(_ transport: Transport, operatorName: String?) -> Line {
        let run = transport.number.map(String.init)
        let description = transport.journeyDescription.map(collapsingSpaces)
        // A regional train's description is only its run number ("29542"); its label or line names it ("RE2").
        let isRunNumber = description.map { !$0.isEmpty && $0.allSatisfy(\.isNumber) } ?? true
        var name = (isRunNumber ? (transport.label ?? transport.line) : nil) ?? description ?? transport.line ?? run ?? "?"
        let product = product(type: transport.type, category: transport.category, name: name)
        switch transport.type {
        case "HIGH_SPEED_TRAIN", "INTERCITY_TRAIN":
            return Line(name: name, number: BahnDeClient.trainNumber(in: name) ?? run, product: product, operatorName: operatorName)
        case "REGIONAL_TRAIN", "INTER_REGIONAL_TRAIN":
            if let run, !name.contains(run) { name += " (\(run))" }
            return Line(name: name, number: run, product: product, operatorName: operatorName, tripNumber: run)
        default:
            let digits = name.split(separator: " ").last.map { String($0.filter(\.isNumber).drop { $0 == "0" }) }
            return Line(name: name, number: digits?.isEmpty == false ? digits : nil, product: product, operatorName: operatorName,
                        tripNumber: run)
        }
    }

    /// "ICE  1005" → "ICE 1005".
    static func collapsingSpaces(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The letters a name starts with, "RE" for "RE2 (29542)" and "ICE" for "ICE 1005".
    static func categoryPrefix(of name: String) -> String {
        String(name.prefix { $0.isLetter }).uppercased()
    }

    static func product(type: String?, category: String?, name: String) -> Product {
        let prefix = categoryPrefix(of: name)
        if ["NJ", "EN"].contains(prefix) { return .nightTrain }
        switch type {
        case "HIGH_SPEED_TRAIN": return .highSpeed
        case "INTERCITY_TRAIN": return .longDistance
        case "INTER_REGIONAL_TRAIN": return .interregio
        case "REGIONAL_TRAIN": return ["RE", "IRE"].contains(prefix) ? .regionalExpress : .regional
        case "CITY_TRAIN": return .suburban
        case "SUBWAY": return .subway
        case "TRAM": return .tram
        case "BUS": return .bus
        case "FERRY": return .ferry
        case nil: break
        default: return .other
        }
        // A trip from bahn.de's journey details only has the category.
        switch (category ?? prefix).uppercased() {
        case "ICE", "ECE", "RJX", "TGV", "FR": return .highSpeed
        case "IC", "EC", "RJ", "D": return .longDistance
        case "IR": return .interregio
        case "RE", "IRE": return .regionalExpress
        case "RB": return .regional
        case "S": return .suburban
        default: return .other
        }
    }

    static func station(_ place: StopPlace, hafasID: String?) -> Station {
        let fields = BahnDeClient.hafasFields(hafasID)
        let coordinate = fields["X"].flatMap(Double.init).flatMap { x in
            fields["Y"].flatMap(Double.init).map { Coordinate(latitude: $0 / 1e6, longitude: x / 1e6) }
        }
        return station(eva: place.evaNumber, name: place.name, coordinate: coordinate)
    }

    static func station(eva: String, name: String, coordinate: Coordinate?) -> Station {
        Station(id: eva, name: name, coordinate: coordinate, evaNumber: eva, source: .bahnDe)
    }

    static func time(_ event: Event) -> TimeInfo {
        time(planned: event.timeSchedule, actual: event.time, type: event.timeType)
    }

    static func time(_ event: ViaEvent) -> TimeInfo {
        time(planned: event.timeSchedule, actual: event.time, type: event.timeType)
    }

    /// Live only when RIS has live data ("PREVIEW", "REAL"); with "SCHEDULE" its `time` is the plan.
    static func time(planned: Date, actual: Date?, type: String?) -> TimeInfo {
        TimeInfo(planned: planned, actual: type == "SCHEDULE" || type == nil ? nil : actual)
    }

    static func platform(_ planned: String?, _ actual: String?) -> PlatformInfo? {
        let info = PlatformInfo(planned: planned, actual: actual)
        return info.best == nil ? nil : info
    }

    static func access(_ messages: [Message]?) -> StopAccess {
        access((messages ?? []).compactMap(\.text))
    }

    /// "Hält nur zum Einsteigen" / "Hält nur zum Aussteigen", as RIS words it.
    static func access(_ texts: [String]) -> StopAccess {
        if texts.contains(where: { $0.localizedCaseInsensitiveContains("nur zum Einsteigen") }) { return .entryOnly }
        if texts.contains(where: { $0.localizedCaseInsensitiveContains("nur zum Aussteigen") }) { return .exitOnly }
        return .normal
    }

    static func unique(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? { self.flatMap { $0.isEmpty ? nil : $0 } }
}
