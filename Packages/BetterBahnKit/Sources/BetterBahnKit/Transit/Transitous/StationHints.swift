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
    static func names(matching query: String, near location: Coordinate, excluding excludedPlace: String? = nil,
                      nearbyOnly: Bool = false, limit: Int = 5, in hints: [Hint] = all) -> [String]
    {
        let typed = TransitousProvider.searchWords(query)
        guard !typed.isEmpty else { return [] }
        let scored: [(name: String, key: String, score: Int)] = hints.compactMap { hint in
            let distance = location.distance(to: hint.coordinate)
            let size = TransitousProvider.sizeScore(forImportance: hint.importance)
            guard distance < radius || (!nearbyOnly && size >= hubSize) else { return nil }
            let words = TransitousProvider.searchWords(Station.displayName(for: hint.name))
            if nearbyOnly, let first = words.first,
               !first.contains(where: { word in typed[0].contains { word.hasPrefix($0) } }) {
                return nil
            }
            var matched: [String] = []
            for spellings in typed {
                let word = words.first { word in word.contains { candidate in spellings.contains { candidate.hasPrefix($0) } } }
                guard let word, let key = word.min() else { return nil }
                matched.append(key)
            }
            return (hint.name, nearbyOnly ? hint.name : matched.joined(separator: " "),
                    TransitousProvider.nearness(forMeters: distance) + size)
        }
        var keys: Set<String> = []
        if let excludedPlace, let town = TransitousProvider.searchWords(excludedPlace).first?.min() { keys.insert(town) }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
            .filter { keys.insert($0.key).inserted }
            .prefix(limit)
            .map(\.name)
    }
}
