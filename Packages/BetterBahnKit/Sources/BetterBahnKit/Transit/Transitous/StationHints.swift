import Foundation

/// Offline list of train stations (name, rough position, how busy), built by
/// `scripts/make-station-hints.py`. The geocoder only returns its best text matches, so "be" never
/// finds Bernau (bei Berlin), however near the user is. This list does, on the device; the app then
/// asks the geocoder for those names, so the stop IDs it uses are always current.
enum StationHints {
    struct Hint: Decodable, Sendable {
        let name: String
        let coordinate: Coordinate
        let importance: Double

        init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            name = try row.decode(String.self)
            coordinate = Coordinate(latitude: try row.decode(Double.self), longitude: try row.decode(Double.self))
            importance = try row.decode(Double.self)
        }
    }

    static let all: [Hint] = {
        guard let url = Bundle.module.url(forResource: "StationHints", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Hint].self, from: data)) ?? []
    }()

    /// Only stations this near are suggested, and the big ones (`hubSize`) from anywhere: "ham" in
    /// Berlin finds Hamburg Hbf, which isn't among the geocoder's hits for it.
    static let radius: Double = 150_000

    /// `TransitousProvider.sizeScore(forImportance:)` from which a station counts however far away.
    static let hubSize = 6

    /// How many points a station whose second word starts with what was typed counts behind one whose
    /// first does (`names(matching:…)`): all of those come first, "wuste" in Berlin asks for
    /// Wustermark rather than Königs Wusterhausen, which the geocoder finds itself.
    static let secondWordBehind = 100

    /// Names of the stations near `location` and the big ones with a word starting with each typed
    /// word, nearest and busiest first (scored like `TransitousProvider.searchRank`'s nearness and
    /// size), one per word that matched: "be" in Berlin gives Berlin Hbf and Bernau, not five Berlin
    /// stations, while "po" gives Potsdamer Platz and Potsdam Hbf. Not those matching only by the
    /// place `excluding` (the user's own town, asked for separately), so "ber" in Berlin finds Bernau
    /// rather than Berlin Hbf.
    ///
    /// `nearbyOnly` is for longer names, which the geocoder finds itself unless there are too many
    /// ("neustadt"): then only stations near `location` count, each on its own, and only those whose
    /// name starts with what was typed, so Neustadt (Dosse) comes before Dresden-Neustadt in Berlin.
    /// Or whose second word does, a bit behind: "travem" for Lübeck-Travemünde Strand, "bad g" for
    /// Bonn Bad Godesberg.
    static func names(matching query: String, near location: Coordinate, excluding excludedPlace: String? = nil,
                      nearbyOnly: Bool = false, limit: Int = 5, in hints: [Hint] = all) -> [String]
    {
        // The start of a word, so a typed umlaut stays one: "kö" for Köln, not Konstanz.
        let typed = TransitousProvider.typedWords(query).map(\.starts)
        guard !typed.isEmpty else { return [] }
        let scored: [(name: String, key: String, score: Int)] = hints.compactMap { hint in
            let distance = location.distance(to: hint.coordinate)
            let size = TransitousProvider.sizeScore(forImportance: hint.importance)
            guard distance < radius || (!nearbyOnly && size >= hubSize) else { return nil }
            let words = TransitousProvider.searchWords(Station.displayName(for: hint.name))
            func startsWithTyped(_ word: Set<String>?) -> Bool {
                word?.contains { word in typed[0].contains { word.hasPrefix($0) } } == true
            }
            // Big stations far away only by their first word: not Köln Messe/Deutz for "me" in Meppen.
            if distance >= radius, !startsWithTyped(TransitousProvider.withoutBad(words, unless: typed[0]).first) {
                return nil
            }
            var behind = 0
            if nearbyOnly {
                let place = TransitousProvider.withoutBad(words, unless: typed[0])
                if !startsWithTyped(place.first) {
                    guard place.count > 1, startsWithTyped(place.dropFirst().first) else { return nil }
                    behind = secondWordBehind
                }
            }
            var matched: [String] = []
            for spellings in typed {
                let word = words.first { word in word.contains { candidate in spellings.contains { candidate.hasPrefix($0) } } }
                guard let word, let key = word.min() else { return nil }
                matched.append(key)
            }
            return (hint.name, nearbyOnly ? hint.name : matched.joined(separator: " "),
                    TransitousProvider.nearness(forMeters: distance) + size - behind)
        }
        var keys: Set<String> = []
        if let excludedPlace, let town = TransitousProvider.searchWords(excludedPlace).first?.min() { keys.insert(town) }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
            .filter { keys.insert($0.key).inserted }
            .prefix(limit)
            .map(\.name)
    }

    /// How far "hbf" or "bahnhof" alone looks for stations (`nearest(to:mainStationsOnly:)`).
    static let nearbyRadius: Double = 30_000

    /// The two nearest stations within `nearbyRadius` (busy ones count a bit nearer), or main stations:
    /// what "hbf" or "bahnhof" means, the geocoder's own hits for those are all around its bias point.
    static func nearest(to location: Coordinate, mainStationsOnly: Bool, limit: Int = 2, in hints: [Hint] = all)
        -> [String]
    {
        hints
            .compactMap { hint -> (name: String, score: Int)? in
                let distance = location.distance(to: hint.coordinate)
                guard distance < nearbyRadius else { return nil }
                if mainStationsOnly, !Station.normalize(Station.displayName(for: hint.name)).contains("hbf") { return nil }
                return (hint.name, TransitousProvider.nearness(forMeters: distance) * 2
                    + TransitousProvider.sizeScore(forImportance: hint.importance))
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
            .prefix(limit)
            .map(\.name)
    }

    /// The busiest station whose place (`TransitousProvider.placeName`) is called `query`, anywhere:
    /// "Bergen Bahnhof" (on Rügen) for "bergen", which isn't among the geocoder's 50 hits (bus stops,
    /// Mons in Belgium). Only its name is asked for, with or without the user's location.
    static func placeStation(named query: String, in hints: [Hint] = all) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, let first = TransitousProvider.searchWords(trimmed).first else { return nil }
        return hints
            .filter { hint in
                // Cheap check first: the name has to start with what was typed.
                guard let word = TransitousProvider.searchWords(hint.name).first, !word.isDisjoint(with: first) else {
                    return false
                }
                let place = TransitousProvider.placeName(Station.displayName(for: hint.name))
                return TransitousProvider.isExactMatch(place, query: trimmed)
            }
            .max { $0.importance < $1.importance }?
            .name
    }
}
