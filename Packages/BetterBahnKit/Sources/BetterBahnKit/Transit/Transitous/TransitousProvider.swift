import Foundation

/// Transitous (https://transitous.org), community-run MOTIS instance with European coverage.
public struct TransitousProvider: TransitProvider {
    public static let defaultBaseURL = URL(string: "https://api.transitous.org/api")!

    public let source = DataSource.transitous
    public var baseURL: URL
    let http: HTTPClient
    /// `coupledTrains(for:)` answers per leg; the timetable doesn't change during the day.
    private let coupledCache = ExpiringCache<[Line.CoupledTrain]>()

    public init(baseURL: URL = TransitousProvider.defaultBaseURL, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.http = http
    }

    func url(_ path: String, _ items: [URLQueryItem]) -> URL {
        baseURL.appending(path: path).appending(queryItems: items)
    }

    public func searchStations(_ query: String) async throws -> [Station] {
        try await searchStations(query, near: nil)
    }

    public func searchStations(_ query: String, near location: Coordinate?) async throws -> [Station] {
        let matches = try await geocode(query, addingMainStation: true)
        let typedTown = matches.contains { Self.isInTown(named: query, $0) }
        // Stable sort by search ranking (then completeness) keeps the API's text ranking within each group.
        let ranked = matches.enumerated()
            .sorted {
                Self.searchRank($0.element, query: query, offset: $0.offset, near: location, typedTown: typedTown)
                    > Self.searchRank($1.element, query: query, offset: $1.offset, near: location, typedTown: typedTown)
            }
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

    /// Search result ordering, by how well the hit matches what was typed first (`textMatchScore`:
    /// "Leipzig Augustusplatz" finds the tram stop before Leipzig Hbf, "Bahnhofstraße Bernau" the
    /// stop in Bernau before other towns' Bahnhofstraße). With `typedTown` (what was typed is the
    /// name of some hit's town), stops in such a town come before same-named places elsewhere:
    /// "München" lists Munich's stations before the village station "München (Bad Berka)".
    /// Then highest tier first:
    /// 1. An exact city+station-name match, as long as it's from Germany or a neighbour above
    ///    (Germany still wins over the neighbours here).
    /// 2. German train stations.
    /// 3. Train stations in Austria, Switzerland, the Netherlands, Poland, Czechia (in that order).
    /// 4. German bus stations.
    /// 5. German U-Bahn stations.
    /// 6. Everything else (other countries, and buses/trams outside Germany).
    /// Within a tier, Hauptbahnhöfe ("… Hbf") come before other stations, then busier stations
    /// before quieter ones.
    ///
    /// With the user's `location`, tiers 2 and 3 become one, ordered by `distanceBands` first: a train
    /// station 50–100 km away comes before one 200–300 km away, whatever country it's in, while
    /// stations within the same band keep the order above. Busy stations count as a few bands nearer
    /// (`bandShift`), so small stations nearby don't push a big one like Frankfurt (M) Hbf down the list.
    static func searchRank(_ match: MGeocodeMatch, query: String, offset: Int, near location: Coordinate? = nil,
                           typedTown: Bool = false) -> (Int, Int, Int, Double, Int, Int)
    {
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
        let displayName = Station.displayName(for: match.fullName)
        // A bus or coach stop named just like its town ("Bonn") stands for the whole town and mustn't
        // beat the town's stations ("Bonn Hbf") for having exactly the name that was typed.
        let namedLikeItsTown = !isTrain && match.town.map { isExactMatch(displayName, query: $0) } == true
        let exactMatch = (isGermany || neighborRank > 0) && !namedLikeItsTown && isExactMatch(displayName, query: query)
        var exactTier = exactMatch ? (isGermany ? 2 : 1) : 0

        // A preferred station also matches exactly on its name without the bracket ("Bernau" for
        // "Bernau (bei Berlin)") and then beats other exact matches - otherwise a bus stop called
        // just "Bernau" would still come first.
        let isPreferred = tier > 0 && preferredStations.contains(displayName)
        if isPreferred, exactMatch || isExactMatch(Self.withoutQualifier(displayName), query: query) {
            exactTier = 3
        }

        // Within a tier, a main station ("Hannover Hbf") outranks its siblings ("Hannover Flughafen").
        let isMainStation = tier > 0 && Station.normalize(Station.displayName(for: match.fullName)).hasSuffix("hbf")

        // Trains in Germany and its neighbours share one group, ordered by distance band, when the
        // user's location is known; otherwise `group` is just `tier` and the order is as above.
        var group = tier * 100
        if let location, tier >= 5 {
            let distance = location.distance(to: Coordinate(latitude: match.lat, longitude: match.lon))
            group = 600 - (Self.distanceBand(forMeters: distance) - Self.bandShift(forImportance: match.importance))
        }
        // A preferred station stays ahead of its tier and every distance band.
        if isPreferred {
            group = tier * 100 + 50
        }

        let textScore = Self.textMatchScore(match, query: query)
        let elsewhere = typedTown && match.town != nil && !Self.isInTown(named: query, match)
        return (textScore * 10 + (elsewhere ? 0 : 5) + exactTier, group, tier * 100 + (isMainStation ? 10 : 0) + neighborRank,
                match.importance ?? 0, match.modes?.count ?? 0, -offset)
    }

    /// How well a hit covers what was typed: per typed word 2 if it's a whole word of the stop's name
    /// or of its town ("Spandau" in "S+U Rathaus Spandau (Berlin)", "Bernau" for a stop just called
    /// "Bahnhofstraße" in Bernau), 1 if a word only starts with it ("Augustusp", "Bonn" in
    /// "Bönningstedt"), 0 otherwise.
    static func textMatchScore(_ match: MGeocodeMatch, query: String) -> Int {
        let names = [match.fullName, Station.displayName(for: match.fullName)] + match.localAreaNames
        let words = Set(names.flatMap { searchWords($0).flatMap { $0 } })
        return searchWords(query).reduce(0) { score, spellings in
            if !spellings.isDisjoint(with: words) { return score + 2 }
            if words.contains(where: { word in spellings.contains { word.hasPrefix($0) } }) { return score + 1 }
            return score
        }
    }

    /// The words of `text`, each with the spellings it should match: lowercased, "ß" as "ss", umlauts
    /// both dropped and spelled out ("köln" and "koeln"), abbreviations also written out
    /// ("Hbf" → "hauptbahnhof", "Hauptstr." → "hauptstrasse").
    static func searchWords(_ text: String) -> [Set<String>] {
        let plain = text.lowercased().replacingOccurrences(of: "ß", with: "ss")
        let spelledOut = plain.replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
        func words(_ text: String) -> [String] {
            text.split { !$0.isLetter && !$0.isNumber }.map { $0.folding(options: .diacriticInsensitive, locale: nil) }
        }
        return zip(words(plain), words(spelledOut)).map { plainWord, spelledOutWord in
            var spellings: Set = [plainWord, spelledOutWord]
            for word in [plainWord, spelledOutWord] {
                if let long = abbreviations[word] { spellings.insert(long) }
                if word.hasSuffix("str") { spellings.insert(word + "asse") }
            }
            return spellings
        }
    }

    /// True if `query` is the name (or the start of the name) of the town `match` is in: "München"
    /// for München Ost, not for the station "München (Bad Berka)" in the town of Bad Berka.
    static func isInTown(named query: String, _ match: MGeocodeMatch) -> Bool {
        guard let town = match.town else { return false }
        let townWords = searchWords(town).flatMap { $0 }
        let typed = searchWords(query)
        return !typed.isEmpty && typed.allSatisfy { spellings in
            townWords.contains { word in spellings.contains { word.hasPrefix($0) } }
        }
    }

    static let abbreviations = ["hbf": "hauptbahnhof", "hauptbf": "hauptbahnhof", "bhf": "bahnhof", "bf": "bahnhof"]

    /// How many distance bands nearer a busy station counts: one per doubling of its `importance`
    /// above 0.001 (a small town's station), at most 4 – so Frankfurt (M) Hbf (~0.02) 425 km from
    /// Berlin counts as near as Frankfurt (Oder) (~0.003) 80 km away.
    static func bandShift(forImportance importance: Double?) -> Int {
        guard let importance, importance > 0.001 else { return 0 }
        return min(4, Int(log2(importance / 0.001)))
    }

    /// "Potsdam" → "Potsdam Hbf": for just a town's name the geocoder can leave its main station
    /// out altogether (none of its 50 hits for "Potsdam" or "Halle" is the Hbf), so it's asked for
    /// separately. Nil for anything that isn't a single word or already names a station.
    static func mainStationQuery(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, !trimmed.contains(where: { $0.isWhitespace || $0.isNumber }) else { return nil }
        let spellings = searchWords(trimmed).flatMap { $0 }
        guard !spellings.contains(where: { $0.hasSuffix("bahnhof") }) else { return nil }
        return trimmed + " Hbf"
    }

    /// Stations that come first among same-named ones even when another is nearer, e.g.
    /// "Bernau (bei Berlin)" before "Bernau am Chiemsee".
    static let preferredStations: Set<String> = ["Bernau (bei Berlin)"]

    /// "Bernau (bei Berlin)" -> "Bernau".
    static func withoutQualifier(_ name: String) -> String {
        guard name.hasSuffix(")"), let openParen = name.range(of: " (", options: .backwards) else { return name }
        return String(name[..<openParen.lowerBound])
    }

    /// Upper bounds (km) of the distance bands search results are grouped into; anything farther
    /// is in one last band.
    static let distanceBands: [Double] = [50, 100, 200, 300, 500, 750, 1000]

    /// 0 for the nearest band (under 50 km), counting up to `distanceBands.count` for 1000 km and more.
    static func distanceBand(forMeters meters: Double) -> Int {
        distanceBands.firstIndex { meters / 1000 < $0 } ?? distanceBands.count
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

    /// With `addingMainStation`, also asks for the town's main station (see `mainStationQuery(for:)`)
    /// and keeps those hits only if they match `query`.
    private func geocode(_ query: String, addingMainStation: Bool = false) async throws -> [MGeocodeMatch] {
        var queries = [query]
        let umlauts = Self.withUmlauts(query)
        if umlauts != query { queries.append(umlauts) }
        let required = queries.count
        if addingMainStation, let mainStation = Self.mainStationQuery(for: query) { queries.append(mainStation) }

        let texts = queries
        let results = try await withThrowingTaskGroup(of: (Int, [MGeocodeMatch]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    guard index >= required else { return (index, try await geocodeRequest(text)) }
                    // Only an extra: if it fails, the search still works without it.
                    let found = (try? await geocodeRequest(text)) ?? []
                    return (index, found.filter { Self.textMatchScore($0, query: query) > 0 })
                }
            }
            var results = Array(repeating: [MGeocodeMatch](), count: texts.count)
            for try await (index, found) in group { results[index] = found }
            return results
        }

        var matches: [MGeocodeMatch] = []
        var indexByID: [String: Int] = [:]
        for found in results {
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

    private func geocodeRequest(_ text: String) async throws -> [MGeocodeMatch] {
        try await http.get(url("v1/geocode", [
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
    /// A main station's name also beats another name for the same stop: Brandenburg's Hbf is also
    /// "Brandenburg, ZOB" (the bus station in front of it).
    static func isBetterName(_ candidate: String, than current: String) -> Bool {
        guard candidate != current else { return false }
        if current.isShoutingCase, !candidate.isShoutingCase { return true }
        if Station.normalize(candidate).contains("hbf"), !Station.normalize(current).contains("hbf") { return true }
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

    private func fetchStopTimes(stopId: String, date: Date, duration: Int, kind: BoardKind, modes: [String]?,
                                count: Int = 150) async throws -> [MStopTime] {
        var items: [URLQueryItem] = [
            .init(name: "stopId", value: stopId),
            .init(name: "time", value: JSONDecoding.isoString(date)),
            .init(name: "n", value: String(count)),
            .init(name: "arriveBy", value: kind == .arrivals ? "true" : "false"),
            // Without it, `arriveBy=true` searches backwards from `time`, so an arrivals board showed
            // days of past arrivals instead of the coming ones.
            .init(name: "direction", value: "LATER"),
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
        let deduplicated = Self.combiningCoupledTrains(Self.deduplicated(entries)).sorted { $0.time.planned < $1.time.planned }
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

    /// Folds board rows of trains coupled together ("Doppeltraktion" under two numbers, e.g. ICE 941
    /// and ICE 951 leaving Hamm together for Berlin) into one row naming both (`Line.coupledTrains`).
    /// Recognized by the same kind of train at the same planned time and platform, going to (or
    /// coming from) the same place – trains that split or join here differ in that place and stay apart.
    static func combiningCoupledTrains(_ entries: [BoardEntry]) -> [BoardEntry] {
        var result: [BoardEntry] = []
        outer: for entry in entries {
            if entry.line.product.isTrain, let platform = entry.platform.planned, let otherEnd = entry.otherEnd {
                for (index, existing) in result.enumerated() {
                    guard existing.kind == entry.kind, existing.line.product == entry.line.product,
                          existing.time.planned == entry.time.planned, existing.platform.planned == platform,
                          existing.cancelled == entry.cancelled,
                          let existingEnd = existing.otherEnd, Station.normalize(existingEnd) == Station.normalize(otherEnd),
                          !existing.line.allNames.map(Line.normalize).contains(Line.normalize(entry.line.name))
                    else { continue }
                    // The row with live data leads, so the board shows the delay.
                    var merged = existing.time.actual == nil && entry.time.actual != nil ? entry : existing
                    let other = merged.tripId == entry.tripId ? existing : entry
                    merged.line.coupledTrains = (merged.line.coupledTrains ?? [])
                        + [Line.CoupledTrain(name: other.line.name, direction: other.kind == .departures ? other.otherEnd : nil,
                                             tripId: other.tripId)]
                        + (other.line.coupledTrains ?? [])
                    result[index] = merged
                    continue outer
                }
            }
            result.append(entry)
        }
        return result
    }

    /// For each long-distance leg, the trains coupled to it from its origin all the way
    /// to its destination, keyed by `Leg.id`: Transitous routes over just one of them (e.g. ICE 950
    /// from Berlin to Hamm, while ICE 940 runs in the same consist up to Hamm, where they split), so
    /// the other one is looked up among the arrivals at the destination and checked against its own
    /// departure at the origin. Legs without coupled trains, or that couldn't be checked, are left out.
    public func coupledTrains(for legs: [Leg]) async -> [String: [Line.CoupledTrain]] {
        let candidates = legs.filter { leg in
            !leg.isWalking && !leg.cancelled && leg.tripId != nil && leg.source == .transitous
                && (leg.line?.product == .highSpeed || leg.line?.product == .longDistance)
        }
        var result: [String: [Line.CoupledTrain]] = [:]
        await withTaskGroup(of: (String, [Line.CoupledTrain]).self) { group in
            for leg in Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values {
                group.addTask {
                    let key = "\(leg.id)|\(leg.destination.id)|\(leg.arrival.planned.timeIntervalSince1970)"
                    let trains = try? await coupledCache.value(for: key, maxAge: 6 * 3600) { try await coupledTrains(for: leg) }
                    return (leg.id, trains ?? [])
                }
            }
            for await (id, trains) in group where !trains.isEmpty { result[id] = trains }
        }
        return result
    }

    private func coupledTrains(for leg: Leg) async throws -> [Line.CoupledTrain] {
        guard let tripId = leg.tripId, let product = leg.line?.product else { return [] }
        // A couple of minutes around the arrival is enough: coupled trains arrive at the very same minute.
        let arrivals = try await fetchStopTimes(stopId: leg.destination.id, date: leg.arrival.planned.addingTimeInterval(-60),
                                                duration: 2, kind: .arrivals, modes: MLineInfo.motisModes(for: product), count: 10)
        guard let own = arrivals.first(where: { $0.tripId == tripId }) else { return [] }
        var trains: [Line.CoupledTrain] = []
        for partner in Self.coupledCandidates(of: own, in: arrivals) {
            // Same arrival isn't enough: the other train may have joined on the way (e.g. two halves
            // from Hamburg and Berlin coupled in Hannover), so it must leave the leg's origin with it too.
            guard let trip = try? await trip(id: partner.tripId),
                  Self.departs(trip, from: leg.origin, at: leg.departure.planned) else { continue }
            trains.append(Line.CoupledTrain(name: partner.lineInfo.toLine().name, direction: trip.direction, tripId: partner.tripId))
        }
        return trains
    }

    /// Arrivals of other trains of the same kind at the same planned minute and platform as `own`.
    static func coupledCandidates(of own: MStopTime, in arrivals: [MStopTime]) -> [MStopTime] {
        guard let arrival = own.place.scheduledArrival else { return [] }
        let ownName = Line.normalize(own.lineInfo.toLine().name)
        var seen: Set<String> = [ownName]
        return arrivals.filter { candidate in
            let name = Line.normalize(candidate.lineInfo.toLine().name)
            guard candidate.tripId != own.tripId, candidate.mode == own.mode,
                  candidate.place.scheduledArrival == arrival,
                  candidate.cancelled != true, candidate.tripCancelled != true,
                  !name.isEmpty, seen.insert(name).inserted else { return false }
            if let ownTrack = own.place.scheduledTrack, let track = candidate.place.scheduledTrack, ownTrack != track { return false }
            return true
        }
    }

    /// Whether `trip` leaves `station` at `plannedDeparture`.
    static func departs(_ trip: Trip, from station: Station, at plannedDeparture: Date) -> Bool {
        trip.stopovers.contains { $0.station.isSamePlace(as: station) && $0.departure?.planned == plannedDeparture }
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
