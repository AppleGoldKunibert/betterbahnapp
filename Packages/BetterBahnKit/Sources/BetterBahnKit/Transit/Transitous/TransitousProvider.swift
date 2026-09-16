import Foundation

/// Transitous (https://transitous.org), community-run MOTIS instance with European coverage.
public struct TransitousProvider: TransitProvider {
    public static let defaultBaseURL = URL(string: "https://api.transitous.org/api")!

    public let source = DataSource.transitous
    public var baseURL: URL
    let http: HTTPClient

    public init(baseURL: URL = TransitousProvider.defaultBaseURL, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.http = http
    }

    func url(_ path: String, _ items: [URLQueryItem]) -> URL {
        baseURL.appending(path: path).appending(queryItems: items)
    }

    public func searchStations(_ query: String) async throws -> [Station] {
        var queries = [query]
        let umlauts = Self.withUmlauts(query)
        if umlauts != query { queries.append(umlauts) }
        var matches: [MGeocodeMatch] = []
        for text in queries {
            let found = try await http.get(url("v1/geocode", [
                .init(name: "text", value: text),
                .init(name: "type", value: "STOP"),
                .init(name: "language", value: "de"),
                .init(name: "place", value: "51.1,10.4"), // bias towards Germany
                .init(name: "placeBias", value: "5"),
            ]), as: [MGeocodeMatch].self)
            matches += found.filter { match in !matches.contains { $0.id == match.id } }
        }
        // Stable sort by relevance keeps the API's text ranking within each group.
        return matches.enumerated()
            .sorted { ($0.element.relevance, -$0.offset) > ($1.element.relevance, -$1.offset) }
            .map { $0.element.toStation() }
    }

    /// "Koeln" → "Köln", so ASCII input still finds the station.
    static func withUmlauts(_ text: String) -> String {
        text.replacingOccurrences(of: "oe", with: "ö")
            .replacingOccurrences(of: "ue", with: "ü")
            .replacingOccurrences(of: "ae", with: "ä")
            .replacingOccurrences(of: "Oe", with: "Ö")
            .replacingOccurrences(of: "Ue", with: "Ü")
            .replacingOccurrences(of: "Ae", with: "Ä")
    }

    /// Maps a station from another source to a Transitous stop (nearest match by name + coordinates).
    public func resolve(_ station: Station) async throws -> Station {
        if station.source == .transitous { return station }
        let candidates = try await searchStations(station.name)
        guard let coordinate = station.coordinate else {
            guard let first = candidates.first else { throw TransitError.notFound(station.name) }
            return first
        }
        let nearest = candidates
            .compactMap { c in c.coordinate.map { (c, $0.distance(to: coordinate)) } }
            .min { $0.1 < $1.1 }
        if let nearest, nearest.1 < 2_000 { return nearest.0 }
        guard let first = candidates.first else { throw TransitError.notFound(station.name) }
        return first
    }

    public func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        async let from = resolve(query.from)
        async let to = resolve(query.to)
        var items: [URLQueryItem] = [
            .init(name: "fromPlace", value: try await from.id),
            .init(name: "toPlace", value: try await to.id),
            .init(name: "time", value: JSONDecoding.isoString(query.date)),
            .init(name: "arriveBy", value: query.isArrival ? "true" : "false"),
            .init(name: "numItineraries", value: "6"),
            .init(name: "detailedTransfers", value: "false"),
        ]
        if let cursor = query.cursor { items.append(.init(name: "pageCursor", value: cursor)) }
        let response = try await http.get(url("v5/plan", items), as: MPlanResponse.self)
        return JourneyPage(
            journeys: response.itineraries.map { Journey(legs: $0.legs.map { $0.toLeg() }, source: .transitous) },
            earlierCursor: response.previousPageCursor,
            laterCursor: response.nextPageCursor,
            source: .transitous
        )
    }

    public func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int) async throws -> [BoardEntry] {
        let stop = try await resolve(station)
        let response = try await http.get(url("v5/stoptimes", [
            .init(name: "stopId", value: stop.id),
            .init(name: "time", value: JSONDecoding.isoString(date)),
            .init(name: "n", value: "150"),
            .init(name: "arriveBy", value: kind == .arrivals ? "true" : "false"),
            .init(name: "window", value: String(duration * 60)),
        ]), as: MStopTimesResponse.self)
        let end = date.addingTimeInterval(TimeInterval(duration * 60))
        return response.stopTimes
            .compactMap { $0.toEntry(kind: kind) }
            .filter { $0.time.planned <= end }
            .sorted { $0.time.planned < $1.time.planned }
    }

    public func trip(id: String) async throws -> Trip {
        let itinerary = try await http.get(url("v5/trip", [.init(name: "tripId", value: id)]), as: MItinerary.self)
        guard let leg = itinerary.legs.first(where: { !$0.isWalking }) else { throw TransitError.notFound("Fahrt") }
        let converted = leg.toLeg()
        return Trip(
            id: id, line: converted.line, direction: leg.headsign, stopovers: converted.stopovers,
            cancelled: converted.cancelled, remarks: [], source: .transitous
        )
    }
}
