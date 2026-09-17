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
        let matches = try await geocode(query)
        // Stable sort by relevance keeps the API's text ranking within each group.
        return matches.enumerated()
            .sorted { ($0.element.relevance, -$0.offset) > ($1.element.relevance, -$1.offset) }
            .map { $0.element.toStation() }
    }

    private func geocode(_ query: String) async throws -> [MGeocodeMatch] {
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
            ]), as: [MGeocodeMatch].self, headers: ["User-Agent": HTTPClient.identifyingUserAgent])
            matches += found.filter { match in !matches.contains { $0.id == match.id } }
        }
        return matches
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
    ///
    /// Several source feeds Transitous merges can each contribute a stop for the very same physical
    /// station with only partial product coverage (e.g. a long-distance-only entry sitting right next
    /// to a fuller one covering regional/suburban too, from a different feed with its own stop ID).
    /// Picking the raw nearest match can land on a partial one and quietly drop a whole product from
    /// the board, so among stops within a small distance of each other the more complete one wins.
    public func resolve(_ station: Station) async throws -> Station {
        if station.source == .transitous { return station }
        let candidates = try await geocode(station.name)
        guard let coordinate = station.coordinate else {
            guard let first = candidates.first else { throw TransitError.notFound(station.name) }
            return first.toStation()
        }
        let byDistance = candidates
            .map { c in (c, Coordinate(latitude: c.lat, longitude: c.lon).distance(to: coordinate)) }
            .filter { $0.1 < 2_000 }
            .sorted { $0.1 < $1.1 }
        guard let nearest = byDistance.first else {
            guard let first = candidates.first else { throw TransitError.notFound(station.name) }
            return first.toStation()
        }
        let nearby = byDistance.filter { $0.1 <= nearest.1 + 300 }
        let mostComplete = nearby.max { $0.0.relevance < $1.0.relevance } ?? nearest
        return mostComplete.0.toStation()
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
        let response = try await http.get(url("v5/plan", items), as: MPlanResponse.self, headers: ["User-Agent": HTTPClient.identifyingUserAgent])
        return JourneyPage(
            journeys: response.itineraries.map { Journey(legs: $0.legs.map { $0.toLeg() }, source: .transitous) },
            earlierCursor: response.previousPageCursor,
            laterCursor: response.nextPageCursor,
            source: .transitous
        )
    }

    public func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] {
        let stop = try await resolve(station)
        var items: [URLQueryItem] = [
            .init(name: "stopId", value: stop.id),
            .init(name: "time", value: JSONDecoding.isoString(date)),
            .init(name: "n", value: "150"),
            .init(name: "arriveBy", value: kind == .arrivals ? "true" : "false"),
            .init(name: "window", value: String(duration * 60)),
        ]
        // A narrowed selection is restricted server-side too, so e.g. rare long-distance trains
        // aren't crowded out of the fixed-size `n` page by frequent regional/S-Bahn departures.
        // `.other` has no known mode mapping, so leave the request unfiltered when it's included.
        if products != Set(Product.allCases), !products.contains(.other) {
            let modes = Set(products.flatMap(MLineInfo.motisModes(for:)))
            if !modes.isEmpty {
                items.append(.init(name: "mode", value: modes.sorted().joined(separator: ",")))
            }
        }
        let response = try await http.get(url("v5/stoptimes", items),
            as: MStopTimesResponse.self, headers: ["User-Agent": HTTPClient.identifyingUserAgent])
        let end = date.addingTimeInterval(TimeInterval(duration * 60))
        let entries = response.stopTimes
            .compactMap { $0.toEntry(kind: kind) }
            .filter { $0.time.planned <= end }
        return Self.deduplicated(entries).sorted { $0.time.planned < $1.time.planned }
    }

    /// Merges board rows that are almost certainly the same physical departure. Transitous stitches
    /// together many feeds, and an international train sometimes gets one row per feed under a
    /// different name — e.g. a Railjet also listed as DB's "ICE 177", usually with only one of them
    /// carrying realtime data. Collapses to one row using whichever has live timing, but keeps the
    /// more specific brand name for display: DB applies its generic "ICE" label even to codeshared
    /// trains from other railways, so it shouldn't win over a more distinctive name (e.g. "RJ") just
    /// because DB's own feed happens to be the one tracking delays. The other name is kept as
    /// `alternateName` either way, so it can still be matched elsewhere (e.g. a Träwelling check-in).
    /// If neither has live data yet (the feed that eventually tracks it hasn't started for this
    /// departure), both rows are kept rather than guessing which is which.
    static func deduplicated(_ entries: [BoardEntry]) -> [BoardEntry] {
        var result: [BoardEntry] = []
        outer: for entry in entries {
            for (index, existing) in result.enumerated() {
                guard existing.kind == entry.kind, existing.time.planned == entry.time.planned,
                      Station.normalize(existing.otherEnd ?? "") == Station.normalize(entry.otherEnd ?? ""),
                      existing.line.name != entry.line.name else { continue }
                let entryIsLive = entry.time.actual != nil
                let existingIsLive = existing.time.actual != nil
                guard entryIsLive != existingIsLive else { continue }
                let live = entryIsLive ? entry : existing
                let stale = entryIsLive ? existing : entry
                var merged = live
                if Self.isGenericICEBrand(live.line.name), !Self.isGenericICEBrand(stale.line.name) {
                    merged.line.name = stale.line.name
                    merged.line.alternateName = live.line.name
                } else {
                    merged.line.alternateName = stale.line.name
                }
                result[index] = merged
                continue outer
            }
            result.append(entry)
        }
        return result
    }

    private static func isGenericICEBrand(_ name: String) -> Bool {
        Line.normalize(name).hasPrefix("ice")
    }

    public func trip(id: String) async throws -> Trip {
        let itinerary = try await http.get(url("v5/trip", [.init(name: "tripId", value: id)]), as: MItinerary.self, headers: ["User-Agent": HTTPClient.identifyingUserAgent])
        guard let leg = itinerary.legs.first(where: { !$0.isWalking }) else { throw TransitError.notFound("Fahrt") }
        let converted = leg.toLeg()
        return Trip(
            id: id, line: converted.line, direction: leg.headsign, stopovers: converted.stopovers,
            cancelled: converted.cancelled, remarks: [], source: .transitous
        )
    }
}
