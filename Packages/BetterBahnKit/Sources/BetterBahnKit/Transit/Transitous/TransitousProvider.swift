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
        try await searchStations(query, near: nil)
    }

    public func searchStations(_ query: String, near location: Coordinate?) async throws -> [Station] {
        let matches = try await geocode(query, addingMainStation: true, near: location)
        let typedTown = matches.contains { Self.isInTown(named: query, $0) }
        // Stable sort by search ranking (then completeness) keeps the API's text ranking within each group.
        let ranked = matches.enumerated()
            .sorted {
                Self.searchRank($0.element, query: query, offset: $0.offset, near: location, typedTown: typedTown)
                    > Self.searchRank($1.element, query: query, offset: $1.offset, near: location, typedTown: typedTown)
            }
            .map { $0.element }
        let merged = Self.mergingNearbyDuplicates(ranked)
        return (location == nil ? merged : Self.spreadingTowns(merged, query: query)).map { $0.toStation() }
    }

    /// How many hits from one town come first before other towns get a turn (see `spreadingTowns`).
    static let hitsPerTown = 3

    /// Keeps the first `hitsPerTown` hits of each town in place and moves the rest behind the other
    /// towns' hits, so "Be" in Berlin lists Bern too, not just five Berlin stations. Not for the town
    /// that was typed: "Berlin" still lists Berlin's stations first.
    static func spreadingTowns(_ ranked: [MGeocodeMatch], query: String) -> [MGeocodeMatch] {
        var countByTown: [String: Int] = [:]
        var first: [MGeocodeMatch] = []
        var rest: [MGeocodeMatch] = []
        for match in ranked {
            guard let town = match.town, !isInTown(named: query, match, wholeWords: true) else {
                first.append(match)
                continue
            }
            countByTown[town, default: 0] += 1
            if countByTown[town, default: 0] > hitsPerTown { rest.append(match) } else { first.append(match) }
        }
        return first + rest
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
    ///
    /// With a `location`, what was typed also counts less strictly (issue #91): first only how many
    /// typed words a hit matches at all (and exact names, as above), then a balance (`nearbyScore`)
    /// of whole words matched, nearness, how busy the station is (`sizeScore`) and being in the town
    /// that was typed. So from Berlin "ber" finds Flughafen BER before Bern and "ost" Berlin
    /// Ostbahnhof before Ulm Ost, a village station doesn't beat a small town's a bit farther away,
    /// while far big stations ("Frankfurt", "München") and full names ("Bern") stay on top. An exact
    /// name only counts for train stations and stops within `localStopDistance`: a bus stop called
    /// "Zoo" in Bavaria doesn't beat Berlin Zoologischer Garten.
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
        // "ber" is Flughafen BER's own short name (`aliases`).
        if isGermany, Self.aliasQuery(for: query).map({ isExactMatch(displayName, query: $0) }) == true {
            exactTier = 2
        }

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
        // How near a train station is (`nearness(forMeters:)`); only with a location.
        var nearness = 0
        let distance = location?.distance(to: Coordinate(latitude: match.lat, longitude: match.lon))
        if let distance, tier >= 5 {
            let band = Self.distanceBand(forMeters: distance)
            group = 600 - (band - Self.bandShift(forImportance: match.importance))
            nearness = Self.nearness(forMeters: distance)
        }
        // A preferred station stays ahead of its tier and every distance band.
        if isPreferred {
            group = tier * 100 + 50
            nearness = Self.distanceBands.count + 3
        }

        let text = Self.textMatch(match, query: query)
        let textRank: Int
        if let location {
            // `nearbyScore` stays well under 100, so it only decides between equal text matches.
            let discount = Self.isSuburbanOnly(modes) ? Self.suburbanDiscount : 0
            let size = max(0, Self.sizeScore(forImportance: match.importance) - discount)
            let nearbyScore = text.whole * 2 + nearness + size
                + (Self.isInTown(named: query, match, wholeWords: true) ? 5 : 0)
            let isLocal = isTrain || (distance ?? .infinity) < Self.localStopDistance
            textRank = (text.matched * 10 + (isLocal ? exactTier : 0)) * 100 + nearbyScore
                - (Self.isFarForeign(match, query: query, isTrain: isTrain, near: location) ? 100_000 : 0)
        } else {
            let elsewhere = typedTown && match.town != nil && !Self.isInTown(named: query, match)
            textRank = (text.matched + text.whole) * 10 + (elsewhere ? 0 : 5) + exactTier
        }
        return (textRank, group, tier * 100 + (isMainStation ? 10 : 0) + neighborRank,
                match.importance ?? 0, match.modes?.count ?? 0, -offset)
    }

    /// Stations abroad within this distance count like German ones.
    static let foreignNearby: Double = 100_000

    /// How near a bus or tram stop must be for its exact name to count (see `searchRank`).
    static let localStopDistance: Double = 50_000

    /// A stop abroad, farther than `foreignNearby`, that isn't a train station in the place that was
    /// typed (`namesPlace`): it comes after every other hit, so "be" in Berlin doesn't list Bern while
    /// "bern" (or "wien", "mailand") still does. Neither "flughafen" (Zürich Flughafen) nor "ost"
    /// (Interlaken Ost) counts as the place, and a bus stop in Ethiopia called "Dil Ber" never does.
    static func isFarForeign(_ match: MGeocodeMatch, query: String, isTrain: Bool, near location: Coordinate) -> Bool {
        guard let country = match.country, country != "DE" else { return false }
        if isTrain, namesPlace(query, match) { return false }
        return location.distance(to: Coordinate(latitude: match.lat, longitude: match.lon)) >= foreignNearby
    }

    /// True if what was typed starts with the first word of `match`'s name or town: "basel" or
    /// "basel bad" for Basel SBB and Basel Bad Bf, "bern" for Bern, not "neustadt" for Wiener Neustadt.
    static func namesPlace(_ query: String, _ match: MGeocodeMatch) -> Bool {
        guard let typed = searchWords(query).first else { return false }
        let names = [Station.displayName(for: match.fullName)] + (match.town.map { [$0] } ?? [])
        return names.contains { name in searchWords(name).first.map { !typed.isDisjoint(with: $0) } == true }
    }

    /// How well a hit covers what was typed: per typed word 2 if it's a whole word of the stop's name
    /// or of its town ("Spandau" in "S+U Rathaus Spandau (Berlin)", "Bernau" for a stop just called
    /// "Bahnhofstraße" in Bernau), 1 if a word only starts with it ("Augustusp", "Bonn" in
    /// "Bönningstedt"), 0 otherwise.
    static func textMatchScore(_ match: MGeocodeMatch, query: String) -> Int {
        let text = textMatch(match, query: query)
        return text.matched + text.whole
    }

    /// How many typed words a hit matches at all (as a whole word or the start of one), and how many
    /// of those as whole words.
    static func textMatch(_ match: MGeocodeMatch, query: String) -> (matched: Int, whole: Int) {
        let names = [match.fullName, Station.displayName(for: match.fullName)] + match.localAreaNames
        let words = Set(names.flatMap { searchWords($0).flatMap { $0 } })
        return searchWords(query).reduce((matched: 0, whole: 0)) { counts, spellings in
            // One or two letters ("Be") only count as the start of a word, not as the Swiss canton
            // in "Brügg BE".
            if spellings.contains(where: { $0.count >= 3 }), !spellings.isDisjoint(with: words) {
                return (counts.matched + 1, counts.whole + 1)
            }
            if words.contains(where: { word in spellings.contains { word.hasPrefix($0) } }) {
                return (counts.matched + 1, counts.whole)
            }
            return counts
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
            if let local = germanNames[spelledOutWord], let localWord = words(local.lowercased()).first {
                spellings.insert(localWord)
            }
            return spellings
        }
    }

    /// True if `query` is the name (or the start of the name) of the town `match` is in: "München"
    /// for München Ost, not for the station "München (Bad Berka)" in the town of Bad Berka.
    /// With `wholeWords`, only full words count, starting with the town's first ("Ost" isn't the town
    /// of Ostrava, "Neustadt" not that of Wiener Neustadt).
    static func isInTown(named query: String, _ match: MGeocodeMatch, wholeWords: Bool = false) -> Bool {
        guard let town = match.town else { return false }
        let townWords = searchWords(town)
        let typed = searchWords(query)
        if wholeWords, let first = typed.first, let townFirst = townWords.first, first.isDisjoint(with: townFirst) {
            return false
        }
        let allTownWords = townWords.flatMap { $0 }
        return !typed.isEmpty && typed.allSatisfy { spellings in
            allTownWords.contains { word in spellings.contains { wholeWords ? word == $0 : word.hasPrefix($0) } }
        }
    }

    static let abbreviations = ["hbf": "hauptbahnhof", "hauptbf": "hauptbahnhof", "bhf": "bahnhof", "bf": "bahnhof"]

    /// German names of towns abroad, by how `searchWords` spells them (umlauts written out), with the
    /// word their stations are named by: the geocoder only knows "Szczecin", so "stettin" finds a bus
    /// stop in Sweden and "Stettiner Straße"s. `searchWords` lets the German name match that word,
    /// and `localNameQuery(for:)` asks the geocoder for it.
    static let germanNames = [
        "stettin": "Szczecin", "breslau": "Wrocław", "danzig": "Gdańsk", "posen": "Poznań",
        "warschau": "Warszawa", "krakau": "Kraków", "kattowitz": "Katowice", "oppeln": "Opole",
        "gleiwitz": "Gliwice", "liegnitz": "Legnica", "bromberg": "Bydgoszcz", "thorn": "Toruń",
        "allenstein": "Olsztyn", "swinemuende": "Świnoujście", "kolberg": "Kołobrzeg", "kuestrin": "Kostrzyn",
        "gruenberg": "Zielona", "hirschberg": "Jelenia", "glogau": "Głogów",
        "prag": "Praha", "pilsen": "Plzeň", "bruenn": "Brno", "olmuetz": "Olomouc", "budweis": "Budějovice",
        "karlsbad": "Karlovy", "marienbad": "Mariánské", "eger": "Cheb", "tetschen": "Děčín",
        "reichenberg": "Liberec", "aussig": "Ústí", "pressburg": "Bratislava", "oedenburg": "Sopron",
        "laibach": "Ljubljana", "agram": "Zagreb",
        "mailand": "Milano", "venedig": "Venezia", "florenz": "Firenze", "neapel": "Napoli", "rom": "Roma",
        "genua": "Genova", "turin": "Torino", "triest": "Trieste", "bozen": "Bolzano", "meran": "Merano",
        "trient": "Trento",
        "genf": "Genève", "neuenburg": "Neuchâtel", "luettich": "Liège", "loewen": "Leuven",
        "bruessel": "Bruxelles", "strassburg": "Strasbourg", "muelhausen": "Mulhouse", "nizza": "Nice",
        "kopenhagen": "København",
    ]

    /// "stettin" → "Szczecin" (`germanNames`), asked for like the main station. Nil if no word of
    /// `query` is a German name of a town abroad.
    static func localNameQuery(for query: String) -> String? {
        let words = query.split(whereSeparator: \.isWhitespace)
        var replaced = false
        let local = words.map { word in
            guard let spellings = searchWords(String(word)).first,
                  let name = spellings.lazy.compactMap({ germanNames[$0] }).first else { return String(word) }
            replaced = true
            return name
        }
        return replaced ? local.joined(separator: " ") : nil
    }

    /// How many distance bands nearer a busy station counts: one per doubling of its `importance`
    /// above 0.001 (a small town's station), at most 4 – so Frankfurt (M) Hbf (~0.02) 425 km from
    /// Berlin counts as near as Frankfurt (Oder) (~0.003) 80 km away.
    static func bandShift(forImportance importance: Double?) -> Int {
        guard let importance, importance > 0.001 else { return 0 }
        return min(4, Int(log2(importance / 0.001)))
    }

    /// How busy a station is, one point per doubling of its `importance` above 0.0001 (a village
    /// station), at most 8 (a big Hbf, ~0.025): a small town's station (~0.0015) gets 3, a village's
    /// 0–1. Worth about as much as a distance band each, so busier stations a little farther away
    /// come first, while a village nearby still beats a busy station far away.
    static func sizeScore(forImportance importance: Double?) -> Int {
        guard let importance, importance > 0.0001 else { return 0 }
        return min(8, Int(log2(importance / 0.0001)))
    }

    /// How many `sizeScore` points a station only served by the S-Bahn loses (a quarter of its
    /// departures): S-Bahn trains run so often that a suburban halt looks as busy as a town's station
    /// with regional and long-distance trains. Still counted, so busy S-Bahn stations stay findable.
    static let suburbanDiscount = 2

    /// True for an S-Bahn station without regional or long-distance trains (buses, trams aside).
    static func isSuburbanOnly(_ modes: Set<String>) -> Bool {
        modes.contains("SUBURBAN") && modes.isDisjoint(with: trainModes.subtracting(["SUBURBAN"]))
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

    /// "Be" → "Be Hbf", "Be Bahnhof": the geocoder answers nothing for under 3 letters, but for these
    /// it lists main and other stations starting with them (Berlin Hbf, Bern, Bebra), which beats
    /// falling back to bahn.de's unordered hits ("Busswil BE", "Murnau-Seeleiten-Be."). Empty from 3
    /// letters on.
    static func shortQueries(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 3, trimmed.allSatisfy(\.isLetter) else { return [] }
        return [trimmed + " Hbf", trimmed + " Bahnhof"]
    }

    /// Short names the geocoder doesn't know: for "ber" none of its 50 hits is Flughafen BER, only
    /// "Flughafen BER" finds it. Asked for as well, like the main station.
    static let aliases = ["ber": "Flughafen BER"]

    static func aliasQuery(for query: String) -> String? {
        aliases[query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// "ost" in Berlin → "Berlin ost", so stations in the user's town are among the candidates (see
    /// `NearbyTowns`). Nil without a location or town nearby, and when what was typed already names
    /// the town or might be the start of it ("ber" in Berlin) – except for one or two letters ("Be"),
    /// which ask for the town itself ("Berlin"), since the geocoder finds nothing for them.
    static func nearbyTownQuery(for query: String, near location: Coordinate?) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let location, !trimmed.isEmpty, let town = NearbyTowns.town(near: location) else { return nil }
        let townWords = searchWords(town).flatMap { $0 }
        let typedWords = searchWords(trimmed).flatMap { $0 }
        let namesTown = typedWords.contains { typed in
            townWords.contains { $0.hasPrefix(typed) || typed.hasPrefix($0) }
        }
        guard namesTown else { return "\(town) \(trimmed)" }
        let startsTown = typedWords.contains { typed in townWords.contains { $0.hasPrefix(typed) } }
        return trimmed.count < 3 && startsTown ? town : nil
    }

    /// Up to how many letters the five best stations from `StationHints` are looked up, near and big
    /// ones. For longer names the geocoder finds the big ones by itself, so only the two best nearby
    /// stations are added: among its 50 hits for "neustadt" or "werder" the one near the user can be
    /// missing.
    static let hintedQueryLength = 4
    static let longQueryHints = 2

    /// "be" near Berlin → "S Bernau Bhf", …: nearby stations starting with what was typed, which the
    /// geocoder wouldn't list for so few letters ("po" → Potsdamer Platz). Only their names go out,
    /// not the location. Leaves out stations matching just by the user's own town's name:
    /// `nearbyTownQuery(for:near:)` covers those, and "ber" in Berlin should still find Flughafen BER
    /// first, not Berlin Hbf.
    static func nearbyStationQueries(for query: String, near location: Coordinate?) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let location, !trimmed.isEmpty else { return [] }
        let town = NearbyTowns.town(near: location)
        guard trimmed.count > hintedQueryLength else {
            return StationHints.names(matching: trimmed, near: location, excluding: town)
        }
        return StationHints.names(matching: trimmed, near: location, excluding: town, nearbyOnly: true,
                                  limit: longQueryHints)
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

    /// Points for how near a station is: `distanceBands.count` under 50 km, one less per band farther
    /// out, down to 0 from 1000 km; plus 1 under 25 km and 2 under 10 km, so the stations around the
    /// user come before those at the edge of the region.
    static func nearness(forMeters meters: Double) -> Int {
        let closeBonus = meters < 10_000 ? 2 : meters < 25_000 ? 1 : 0
        return distanceBands.count - distanceBand(forMeters: meters) + closeBonus
    }

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

    /// With `addingMainStation`, also asks for the town's main station (see `mainStationQuery(for:)`,
    /// `shortQueries(for:)`), a known short name (`aliasQuery(for:)`) and, `near` a location, stations
    /// in the user's town (`nearbyTownQuery(for:near:)`) and nearby ones
    /// (`nearbyStationQueries(for:near:)`), and keeps those hits only if they match `query`.
    private func geocode(_ query: String, addingMainStation: Bool = false, near location: Coordinate? = nil)
        async throws -> [MGeocodeMatch]
    {
        var queries = [query]
        let umlauts = Self.withUmlauts(query)
        if umlauts != query { queries.append(umlauts) }
        let required = queries.count
        if addingMainStation {
            let extras = [Self.mainStationQuery(for: query), Self.aliasQuery(for: query),
                          Self.localNameQuery(for: query), Self.nearbyTownQuery(for: query, near: location)]
            queries += Self.shortQueries(for: query) + extras.compactMap { $0 }
            let known = queries
            queries += Self.nearbyStationQueries(for: query, near: location).filter { !known.contains($0) }
        }

        let texts = queries
        let results = try await withThrowingTaskGroup(of: (Int, [MGeocodeMatch]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    guard index >= required else { return (index, try await geocodeRequest(text)) }
                    // Only an extra: if it fails or is slow, the search still works without it. Waiting
                    // for it longer would run into `CombinedProvider`'s deadline and lose every hit.
                    let found = (try? await CombinedProvider.withDeadline(Self.extraQueryDeadline) {
                        try await geocodeRequest(text)
                    }) ?? []
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

    /// How long the extra geocoder queries (main station, nearby town and stations, …) may take,
    /// well within `CombinedProvider`'s 2.5 s for the whole station search.
    static let extraQueryDeadline: Duration = .milliseconds(1800)

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

    private func fetchStopTimes(stopId: String, date: Date, duration: Int, kind: BoardKind, modes: [String]?) async throws -> [MStopTime] {
        var items: [URLQueryItem] = [
            .init(name: "stopId", value: stopId),
            .init(name: "time", value: JSONDecoding.isoString(date)),
            .init(name: "n", value: "150"),
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
