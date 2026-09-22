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
        // Stable sort by search ranking (then completeness) keeps the API's text ranking within each group.
        let ranked = matches.enumerated()
            .sorted { Self.searchRank($0.element, query: query, offset: $0.offset) > Self.searchRank($1.element, query: query, offset: $1.offset) }
            .map { $0.element }
        return Self.mergingNearbyDuplicates(ranked).map { $0.toStation() }
    }

    private static func completeness(_ match: MGeocodeMatch, _ offset: Int) -> (Int, Int, Int) {
        (match.relevance, match.modes?.count ?? 0, -offset)
    }

    private static let trainModes: Set<String> = [
        "HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL",
        "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "RAIL",
    ]
    private static let busModes: Set<String> = ["BUS", "COACH"]
    private static let subwayModes: Set<String> = ["SUBWAY", "METRO"]

    /// Germany's rail neighbours worth surfacing early, ranked in this order (Germany itself always
    /// comes first and isn't in this table).
    private static let neighboringCountryRank: [String: Int] = [
        "AT": 5, "CH": 4, "NL": 3, "PL": 2, "CZ": 1,
    ]

    /// Search result ordering, highest tier first:
    /// 1. An exact city+station-name match, as long as it's from Germany or a neighbour above
    ///    (Germany still wins over the neighbours here).
    /// 2. German train stations.
    /// 3. Train stations in Austria, Switzerland, the Netherlands, Poland, Czechia (in that order).
    /// 4. German bus stations.
    /// 5. German U-Bahn stations.
    /// 6. Everything else (other countries, and buses/trams outside Germany).
    /// Within a tier, Hauptbahnhöfe ("… Hbf") come before other stations.
    static func searchRank(_ match: MGeocodeMatch, query: String, offset: Int) -> (Int, Int, Int, Int, Int, Int) {
        let modes = Set(match.modes ?? [])
        let isTrain = !modes.isDisjoint(with: trainModes)
        let isBus = !modes.isDisjoint(with: busModes)
        let isSubway = !modes.isDisjoint(with: subwayModes)
        let isGermany = match.country == "DE"
        let neighborRank = match.country.flatMap { neighboringCountryRank[$0] } ?? 0

        let tier: Int
        if isTrain, isGermany {
            tier = 6
        } else if isTrain, neighborRank > 0 {
            tier = 5
        } else if isBus, isGermany {
            tier = 4
        } else if isSubway, isGermany {
            tier = 3
        } else {
            tier = 0
        }

        // Compared against the cleaned display name, not the raw feed name: two feeds for the very
        // same physical station can format that raw name completely differently (DELFI's
        // "S+U Gesundbrunnen Bhf (Berlin)" vs. another feed's plain "Berlin Gesundbrunnen"), and
        // comparing raw strings would hand the exact-match bonus to whichever feed's formatting
        // happens to read like common usage – regardless of which one actually has fuller product
        // coverage – undoing `mergingNearbyDuplicates`'s completeness-based pick for that cluster.
        let exactMatch = (isGermany || neighborRank > 0) && isExactMatch(Station.displayName(for: match.name), query: query)
        let exactTier = exactMatch ? (isGermany ? 2 : 1) : 0

        // Within a tier, a main station ("Hannover Hbf") outranks its siblings ("Hannover Flughafen").
        let isMainStation = tier > 0 && Station.normalize(Station.displayName(for: match.name)).hasSuffix("hbf")

        return (exactTier, tier, isMainStation ? 1 : 0, neighborRank, match.modes?.count ?? 0, -offset)
    }

    /// True if `name` is the same place name the user typed (e.g. "Berlin Hauptbahnhof"), ignoring
    /// case, diacritics, and ASCII-vs-umlaut spelling ("Koeln Hbf" vs. "Köln Hbf").
    static func isExactMatch(_ name: String, query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return false }
        for candidate in [trimmedQuery, withUmlauts(trimmedQuery)] {
            if name.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// Several source feeds Transitous merges can each surface the very same physical station as a
    /// separate geocode hit under its own ID (see `resolve(_:)`'s doc comment) — one row per feed,
    /// often with a differently formatted name and only partial product coverage. Left as-is, that
    /// turns into several confusingly similar-looking suggestions for one place in the station
    /// picker, and picking the less complete one silently drops whole products from its board.
    /// Once candidates are ranked by completeness, folds any hit within `duplicateRadius` of an
    /// already-kept one into it — it's certainly the same stop under another feed's ID.
    static let duplicateRadius: Double = 200

    static func mergingNearbyDuplicates(_ ranked: [MGeocodeMatch]) -> [MGeocodeMatch] {
        var kept: [MGeocodeMatch] = []
        outer: for match in ranked {
            let coordinate = Coordinate(latitude: match.lat, longitude: match.lon)
            for existing in kept {
                let existingCoordinate = Coordinate(latitude: existing.lat, longitude: existing.lon)
                if coordinate.distance(to: existingCoordinate) < duplicateRadius { continue outer }
            }
            kept.append(match)
        }
        return kept
    }

    private func geocode(_ query: String) async throws -> [MGeocodeMatch] {
        var queries = [query]
        let umlauts = Self.withUmlauts(query)
        if umlauts != query { queries.append(umlauts) }
        var matches: [MGeocodeMatch] = []
        var indexByID: [String: Int] = [:]
        for text in queries {
            let found = try await http.get(url("v1/geocode", [
                .init(name: "text", value: text),
                .init(name: "type", value: "STOP"),
                .init(name: "language", value: "de"),
                .init(name: "place", value: "51.1,10.4"), // bias towards Germany
                .init(name: "placeBias", value: "5"),
                // The API's own text-relevance ranking defaults to 10 hits and buries real train
                // stations under a pile of similarly-named bus stops when a common name is shared
                // across many places (e.g. "Bernau" matches dozens of tiny stops before it reaches
                // "Bernau a. Chiemsee"). Asking for more candidates gives `searchRank` below –
                // which already knows to prefer trains – enough to actually find.
                .init(name: "numResults", value: "50"),
            ]), as: [MGeocodeMatch].self, headers: ["User-Agent": HTTPClient.identifyingUserAgent])
            for match in found {
                if let existingIndex = indexByID[match.id] {
                    if Self.isBetterName(match.name, than: matches[existingIndex].name) {
                        matches[existingIndex].name = match.name
                    }
                } else {
                    indexByID[match.id] = matches.count
                    matches.append(match)
                }
            }
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

    /// European rail reference data commonly carries an all-caps, umlaut-free alias for a station
    /// ("MUENCHEN HBF", "Berlin Suedkreuz") alongside its properly written local name ("München Hbf",
    /// "Berlin Südkreuz") — and the geocoder echoes back whichever alias actually matched the query
    /// text. Since `geocode(_:)` re-queries with an umlaut-normalized version of anything the caller
    /// typed in ASCII, the same stop ID can turn up under both names; prefer the properly written one.
    static func isBetterName(_ candidate: String, than current: String) -> Bool {
        guard candidate != current else { return false }
        if current.isShoutingCase, !candidate.isShoutingCase { return true }
        return Self.withUmlauts(current) == candidate
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
        let mostComplete = nearby.max { Self.completeness($0.0, 0) < Self.completeness($1.0, 0) } ?? nearest
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
        if let maxTransfers = query.maxTransfers { items.append(.init(name: "maxTransfers", value: String(maxTransfers))) }
        // `.other` has no known mode mapping, so a selection containing it stays unfiltered server-side.
        if query.products != Set(Product.allCases), !query.products.contains(.other) {
            let modes = Set(query.products.flatMap(MLineInfo.motisModes(for:)))
            if !modes.isEmpty { items.append(.init(name: "transitModes", value: modes.sorted().joined(separator: ","))) }
        }
        let response = try await http.get(url("v5/plan", items), as: MPlanResponse.self, headers: ["User-Agent": HTTPClient.identifyingUserAgent])
        return JourneyPage(
            journeys: response.itineraries
                .map { Journey(legs: Self.mergeThroughTrainLegs($0.legs.map { $0.toLeg() }), source: .transitous) }
                .filter(query.allows),
            earlierCursor: response.previousPageCursor,
            laterCursor: response.nextPageCursor,
            source: .transitous
        )
    }

    /// Collapses two legs that are really one continuous physical train ride which Transitous split
    /// at a border because its constituent feeds model the two halves as separate trips — e.g. a
    /// Berlin–Amsterdam ICE whose German feed data ends at Hengelo (both `to` and `headsign` say
    /// "Hengelo") while the Dutch feed's own trip record picks up right there and continues to
    /// Amsterdam Centraal, or a Berlin–Warszawa EuroCity that Deutsche Bahn's domestic feed only
    /// brands as a generic "IC" up to the border while the Polish feed correctly brands its half "EC".
    /// Recognized by the same train number continuing from exactly where the previous leg ends with no
    /// real dwell time — a same-train, back-to-back "transfer" that isn't one. The two legs are
    /// sometimes truly adjacent, and sometimes separated by a short "walk" leg this data inserts
    /// between two stops that are really the same platform under different feeds (e.g. a Dutch feed's
    /// "Rheine" and the German feed's "Rheine, Bahnhof" for an Amsterdam–Hannover ICE, ~50 m apart) —
    /// that walk is folded away too rather than shown as a change.
    static func mergeThroughTrainLegs(_ legs: [Leg]) -> [Leg] {
        var result: [Leg] = []
        for leg in legs {
            if !leg.isWalking, let anchorIndex = continuationAnchorIndex(in: result, for: leg) {
                let anchor = result[anchorIndex]
                var merged = anchor
                merged.destination = leg.destination
                merged.arrival = leg.arrival
                merged.arrivalPlatform = leg.arrivalPlatform
                merged.direction = leg.direction ?? leg.destination.displayName
                merged.line = Self.preferredLine(anchor.line, leg.line)
                merged.cancelled = anchor.cancelled || leg.cancelled
                merged.stopovers = anchor.stopovers + leg.stopovers.dropFirst()
                merged.remarks = anchor.remarks + leg.remarks
                switch (anchor.geometry, leg.geometry) {
                case let (a?, b?): merged.geometry = a + b
                case let (a?, nil): merged.geometry = a
                case let (nil, b?): merged.geometry = b
                case (nil, nil): merged.geometry = nil
                }
                result.removeLast(result.count - anchorIndex)
                result.append(merged)
                continue
            }
            result.append(leg)
        }
        return result
    }

    /// Index of the most recent leg in `result` that `leg` is really a direct continuation of –
    /// either truly back-to-back, or separated only by a single short walk leg bridging two stops
    /// that are really the same platform (see `mergeThroughTrainLegs` above). Recognized by the same
    /// train number and product continuing with no real dwell time between the two train legs' own
    /// planned times — the walk leg's own bounds don't factor in, only that it doesn't hide an actual
    /// transfer.
    static func continuationAnchorIndex(in result: [Leg], for leg: Leg) -> Int? {
        guard let lastIndex = result.indices.last else { return nil }
        let last = result[lastIndex]
        let anchorIndex = last.isWalking ? lastIndex - 1 : lastIndex
        guard anchorIndex >= 0, !result[anchorIndex].isWalking else { return nil }
        let anchor = result[anchorIndex]
        let bridged = last.isWalking
            ? anchor.destination.isSamePlace(as: last.origin) && last.destination.isSamePlace(as: leg.origin)
            : anchor.destination.isSamePlace(as: leg.origin)
        guard bridged,
              anchor.line?.product == leg.line?.product,
              let anchorNumber = anchor.line?.number, anchorNumber == leg.line?.number,
              leg.departure.planned.timeIntervalSince(anchor.arrival.planned) <= 5 * 60
        else { return nil }
        return anchorIndex
    }

    /// A domestic feed sometimes genericizes an international EuroCity as a plain "IC"; when the
    /// continuing leg's own feed names it "EC" for the very same numbered train, that's the real brand.
    static func preferredLine(_ first: Line?, _ second: Line?) -> Line? {
        guard let first, let second else { return first ?? second }
        let firstNormalized = Line.normalize(first.name)
        if firstNormalized.hasPrefix("ic"), !firstNormalized.hasPrefix("ice"), Line.normalize(second.name).hasPrefix("ec") {
            return second
        }
        return first
    }

    /// Modes rare enough, next to a busy station's local traffic, to get crowded out of the
    /// fixed-size `n` stoptimes page entirely before their own departure is ever reached (see
    /// `board(_:at:date:duration:products:)`).
    private static let longDistanceModes: [Product] = [.highSpeed, .longDistance]

    private func fetchStopTimes(stopId: String, date: Date, duration: Int, kind: BoardKind, modes: [String]?) async throws -> [MStopTime] {
        var items: [URLQueryItem] = [
            .init(name: "stopId", value: stopId),
            .init(name: "time", value: JSONDecoding.isoString(date)),
            .init(name: "n", value: "150"),
            .init(name: "arriveBy", value: kind == .arrivals ? "true" : "false"),
            .init(name: "window", value: String(duration * 60)),
        ]
        if let modes, !modes.isEmpty {
            items.append(.init(name: "mode", value: modes.sorted().joined(separator: ",")))
        }
        let response = try await http.get(url("v5/stoptimes", items),
            as: MStopTimesResponse.self, headers: ["User-Agent": HTTPClient.identifyingUserAgent])
        return response.stopTimes
    }

    public func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] {
        let stop = try await resolve(station)

        // A narrowed selection is restricted server-side too, so e.g. rare long-distance trains
        // aren't crowded out of the fixed-size `n` page by frequent regional/S-Bahn departures.
        // `.other` has no known mode mapping, so leave that branch of the request unfiltered.
        let stopTimes: [MStopTime]
        if products != Set(Product.allCases), !products.contains(.other) {
            let modes = Set(products.flatMap(MLineInfo.motisModes(for:)))
            stopTimes = try await fetchStopTimes(stopId: stop.id, date: date, duration: duration, kind: kind,
                                                 modes: modes.isEmpty ? nil : Array(modes))
        } else if products.contains(.highSpeed) || products.contains(.longDistance) {
            // Unfiltered (or `.other`-inclusive) requests would otherwise send no `mode` param at
            // all, so at a busy multimodal hub (e.g. Amsterdam Centraal, with dozens of bus/tram/
            // metro/ferry departures sharing the stop cluster) the fixed-size page can fill up with
            // local traffic within minutes, hiding long-distance/high-speed trains scheduled later
            // in the requested window entirely – not just pushed down, genuinely absent. Fetch that
            // slice in its own request so it's never starved by everything else.
            let longDistanceModes = Set(Self.longDistanceModes.filter(products.contains).flatMap(MLineInfo.motisModes(for:)))
            async let longDistance = fetchStopTimes(stopId: stop.id, date: date, duration: duration, kind: kind,
                                                     modes: Array(longDistanceModes))
            async let rest = fetchStopTimes(stopId: stop.id, date: date, duration: duration, kind: kind, modes: nil)
            var seenTripIds = Set<String>()
            stopTimes = try await (longDistance + rest).filter { seenTripIds.insert($0.tripId).inserted }
        } else {
            stopTimes = try await fetchStopTimes(stopId: stop.id, date: date, duration: duration, kind: kind, modes: nil)
        }

        let end = date.addingTimeInterval(TimeInterval(duration * 60))
        let entries = Self.mergeBorderSplitDuplicates(stopTimes, kind: kind)
            .compactMap { $0.toEntry(kind: kind) }
            .filter { $0.time.planned <= end }
        let deduplicated = Self.deduplicated(entries).sorted { $0.time.planned < $1.time.planned }
        return await withCorrectedLongDistanceEnds(deduplicated, kind: kind)
    }

    /// `/v5/stoptimes` reports a long-distance train's `headsign`/final stop as wherever *this
    /// station's own feed* stops modelling the trip — e.g. a Berlin–Amsterdam ICE whose German feed
    /// data ends at Hengelo, or a cross-border EuroCity a domestic feed only brands as a plain "IC" up
    /// to the border. `/v5/trip` for that same trip id resolves the full, interlined route instead
    /// (confirmed: the very same trip id reports "Amsterdam Centraal" there, not "Hengelo"), so board
    /// rows are corrected against it. Scoped to long-distance/high-speed rows only, since a station
    /// board rarely has more than a handful at once and this is one extra request per row.
    private func withCorrectedLongDistanceEnds(_ entries: [BoardEntry], kind: BoardKind) async -> [BoardEntry] {
        let candidates = entries.enumerated().filter { $0.element.line.product == .highSpeed || $0.element.line.product == .longDistance }
        guard !candidates.isEmpty else { return entries }
        var result = entries
        await withTaskGroup(of: (Int, Trip?).self) { group in
            for (index, entry) in candidates {
                group.addTask { (index, try? await self.trip(id: entry.tripId)) }
            }
            for await (index, trip) in group {
                guard let trip else { continue }
                if kind == .departures, let direction = trip.direction, !direction.isEmpty {
                    result[index].otherEnd = direction
                } else if kind == .arrivals, let origin = trip.origin {
                    result[index].otherEnd = origin.displayName
                }
                if let correctedLine = trip.line, correctedLine.name != result[index].line.name {
                    result[index].line.alternateName = result[index].line.alternateName ?? result[index].line.name
                    result[index].line.name = correctedLine.name
                    result[index].line.number = correctedLine.number
                }
            }
        }
        return result
    }

    /// Collapses stoptime rows for the very same physical train that Transitous' constituent feeds
    /// disagree about past a border. A domestic feed (e.g. Deutsche Bahn's own GTFS-DE data) sometimes
    /// only models a cross-border service up to the last stop before the border, with `headsign` set
    /// to that same stop, while the neighbouring country's feed for the identical physical run keeps
    /// the true final destination as `headsign` even though its own trip record also happens to end
    /// there (e.g. a Munich–Bologna Railjet, run under DB's "ICE 87" too, whose German feed entry says
    /// "Kufstein" — its own last stop — while the Austrian feed's entry correctly says "Bologna").
    /// Prefer whichever row names a destination beyond its own last stop.
    static func mergeBorderSplitDuplicates(_ stopTimes: [MStopTime], kind: BoardKind) -> [MStopTime] {
        var result: [MStopTime] = []
        outer: for stopTime in stopTimes {
            for (index, existing) in result.enumerated() {
                let plannedTimeMatches = kind == .departures
                    ? existing.place.scheduledDeparture == stopTime.place.scheduledDeparture
                    : existing.place.scheduledArrival == stopTime.place.scheduledArrival
                guard existing.tripId != stopTime.tripId, plannedTimeMatches,
                      let number = existing.lineInfo.toLine().number, number == stopTime.lineInfo.toLine().number
                else { continue }
                let existingEnd = kind == .departures ? existing.tripTo : existing.tripFrom
                let candidateEnd = kind == .departures ? stopTime.tripTo : stopTime.tripFrom
                let existingKnowsContinuation = Self.namesContinuation(headsign: existing.headsign, ownEnd: existingEnd)
                let candidateKnowsContinuation = Self.namesContinuation(headsign: stopTime.headsign, ownEnd: candidateEnd)
                guard existingKnowsContinuation != candidateKnowsContinuation else { continue }
                if candidateKnowsContinuation { result[index] = stopTime }
                continue outer
            }
            result.append(stopTime)
        }
        return result
    }

    private static func namesContinuation(headsign: String?, ownEnd: MPlace?) -> Bool {
        guard let headsign, let ownEnd else { return false }
        return Station.normalize(headsign) != Station.normalize(ownEnd.stationName)
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
            id: id, line: converted.line, direction: converted.direction, stopovers: converted.stopovers,
            cancelled: converted.cancelled, remarks: [], source: .transitous
        )
    }
}

private extension String {
    /// True for an all-caps alias like "MUENCHEN HBF" rather than a properly written name.
    var isShoutingCase: Bool { self == uppercased() && self != lowercased() }
}
