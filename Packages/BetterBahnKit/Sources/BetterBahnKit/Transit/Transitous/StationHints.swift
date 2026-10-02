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

    /// Only stations this near are suggested.
    static let radius: Double = 150_000

    /// Names of the stations near `location` with a word starting with each typed word, nearest and
    /// busiest first (scored like `TransitousProvider.searchRank`'s nearness and size), one per word
    /// that matched: "be" in Berlin gives Berlin Hbf and Bernau, not five Berlin stations, while "po"
    /// gives Potsdamer Platz and Potsdam Hbf. Not those matching only by the place `excluding` (the
    /// user's own town, asked for separately), so "ber" in Berlin finds Bernau rather than Berlin Hbf.
    static func names(matching query: String, near location: Coordinate, excluding excludedPlace: String? = nil,
                      limit: Int = 5, in hints: [Hint] = all) -> [String]
    {
        let typed = TransitousProvider.searchWords(query)
        guard !typed.isEmpty else { return [] }
        let scored: [(name: String, key: String, score: Int)] = hints.compactMap { hint in
            let distance = location.distance(to: hint.coordinate)
            guard distance < radius else { return nil }
            let words = TransitousProvider.searchWords(Station.displayName(for: hint.name))
            var matched: [String] = []
            for spellings in typed {
                let word = words.first { word in word.contains { candidate in spellings.contains { candidate.hasPrefix($0) } } }
                guard let word, let key = word.min() else { return nil }
                matched.append(key)
            }
            let nearness = TransitousProvider.distanceBands.count - TransitousProvider.distanceBand(forMeters: distance)
            return (hint.name, matched.joined(separator: " "),
                    nearness + TransitousProvider.sizeScore(forImportance: hint.importance))
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
