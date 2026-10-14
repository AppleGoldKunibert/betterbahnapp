import Foundation

/// DB's RIL100 station codes ("FF" Frankfurt (Main) Hbf, "AH" Hamburg Hbf), from the offline list
/// `Resources/Ril100.json` built by `scripts/make-ril100.py` from DB InfraGO's operating points
/// (Deutsche Bahn AG, CC BY 4.0) (#165). Station search finds a station by its code, typed in any
/// case; the picker can show a station's code next to its name. DB's list has no EVA numbers, so
/// stops are matched to codes by position and name. Stations abroad ("XS ZH" Zürich HB: X + country
/// letter, Z for eastern Europe) come from DB's other list of operating points and have no
/// positions: they are matched by their exact name or, within their country, by a looser one
/// ("Utrecht C" is "Utrecht Centraal", "Aalborg" is "Aalborg St.").
public enum Ril100 {
    public struct Entry: Decodable, Sendable, Hashable {
        /// E.g. "FF", or "LL T" for Leipzig Hbf's lower level.
        public let code: String
        /// DB's name, e.g. "Berlin Hauptbahnhof - Lehrter Bahnhof".
        public let name: String
        /// Where the station lies on each of its lines: a big one spans kilometres. Empty for
        /// stations abroad.
        public let points: [Coordinate]

        /// What a stop abroad may be called to be this station, exactly (`exactNameKey`) or loosely
        /// (`looseNameKey`); both empty with positions.
        let abroadNameKeys: Set<String>
        let abroadLooseKeys: Set<String>

        init(code: String, name: String, points: [Coordinate]) {
            self.code = code
            self.name = name
            self.points = points
            abroadNameKeys = points.isEmpty ? Ril100.abroadNameKeys(for: name) : []
            abroadLooseKeys = points.isEmpty ? Ril100.abroadLooseKeys(for: name) : []
        }

        public init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            code = try row.decode(String.self)
            name = try row.decode(String.self)
            let flat = try row.decode([Double].self)
            points = stride(from: 0, to: flat.count - 1, by: 2).map { Coordinate(latitude: flat[$0], longitude: flat[$0 + 1]) }
            abroadNameKeys = points.isEmpty ? Ril100.abroadNameKeys(for: name) : []
            abroadLooseKeys = points.isEmpty ? Ril100.abroadLooseKeys(for: name) : []
        }

        var nameKey: String { Ril100.nameKey(name) }

        /// True for a station abroad ("XSZH"), which DB's list gives no position.
        var isAbroad: Bool { points.isEmpty }
    }

    static let all: [Entry] = {
        guard let url = Bundle.module.url(forResource: "Ril100", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    /// Loads the list off the calling thread, so the first code shown or searched doesn't wait for it
    /// (decoding it and the names of the stations abroad takes a fraction of a second).
    public static func preload() async {
        await Task.detached(priority: .utility) { _ = all }.value
    }

    private static let byCode: [String: Entry] = Dictionary(all.map { (codeKey($0.code), $0) }) { first, _ in first }

    /// Upper case with single spaces: DB writes "LL  T" with two.
    static func codeKey(_ text: String) -> String {
        text.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A name as the app shows it, without the parts in brackets, spaces and case, as feeds write
    /// those differently: "Berlin Hauptbahnhof" → "berlinhbf", "Frankfurt (M) Hbf" and
    /// "Frankfurt (Main) Hbf" → "frankfurthbf". Same-named towns are told apart by position.
    static func nameKey(_ name: String) -> String {
        let shown = Station.displayName(for: name)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        return Station.normalize(shown)
    }

    /// What to ask the geocoder for a station, as it often misses DB's full name ("Hof Hbf",
    /// "Berlin Hauptbahnhof - Lehrter Bahnhof"): the name, the part before " - " and the town.
    static func searchTexts(for name: String) -> [String] {
        let short = name.components(separatedBy: " - ")[0]
        let town = short.split { $0 == " " || $0 == "(" || $0 == "-" }.first.map(String.init) ?? short
        var texts: [String] = []
        for text in [name, short, town] where !texts.contains(text) { texts.append(text) }
        return texts
    }

    /// The station whose code is exactly what was typed, in any case: "ff" → Frankfurt (Main) Hbf.
    public static func entry(forCode text: String) -> Entry? {
        let key = codeKey(text)
        guard (2...6).contains(key.count) else { return nil }
        return byCode[key]
    }

    /// How far a stop may be from one of DB's positions of the station and still count as it.
    static let matchRadius: Double = 600

    /// Nearer than this, a stop counts as the station whatever it's called ("Frankfurt(M) Hbf").
    static let sameSpotRadius: Double = 80

    /// A name for comparing stations abroad: brackets kept ("Hof (Saale)" is not an Austrian "Hof"),
    /// but not a country mark ("Basel SBB (CH)"); spaces, case, accents and "Hauptbahnhof" ignored, as
    /// DB writes "Wroclaw Glowny" and feeds "Wrocław Główny".
    static func exactNameKey(_ name: String) -> String {
        let shown = withoutCountryMark(Station.displayName(for: name))
            .replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: "Ł", with: "L")
        return Station.normalize(shown.folding(options: .diacriticInsensitive, locale: nil))
    }

    /// The names a stop abroad may have to be the station `name`: the whole name, or one of the two names
    /// of a station DB gives both ("Bruxelles-Midi / Brussel-Zuid").
    static func abroadNameKeys(for name: String) -> Set<String> {
        Set(nameParts(of: name).map(exactNameKey).filter { !$0.isEmpty })
    }

    static func abroadLooseKeys(for name: String) -> Set<String> {
        Set(nameParts(of: name).map(looseNameKey).filter { !$0.isEmpty })
    }

    private static func nameParts(of name: String) -> [String] {
        var parts = [name]
        for separator in [" / ", " - "] where name.contains(separator) { parts += name.components(separatedBy: separator) }
        return parts
    }

    /// `name` without a country mark at its end: "Basel SBB (CH)" → "Basel SBB".
    private static func withoutCountryMark(_ name: String) -> String {
        let characters = Array(name)
        guard characters.count > 5, characters[characters.count - 1] == ")", characters[characters.count - 4] == "(",
              characters[characters.count - 5] == " ",
              characters[characters.count - 3].isASCII, characters[characters.count - 3].isUppercase,
              characters[characters.count - 2].isASCII, characters[characters.count - 2].isUppercase else { return name }
        return String(characters.dropLast(5))
    }

    /// Words feeds put after a station's name ("Friesach Bahnhof", "Aalborg St.", "Voss stasjon",
    /// "Luxembourg Ville") that DB's name leaves out.
    private static let trailingStationWords: Set<String> = [
        "bahnhof", "bhf", "station", "stasjon", "st", "stn", "gare", "ville", "stazione", "bf", "central",
    ]

    /// DB's and the feeds' short forms of "Centraal"/"Centralstation": "Utrecht C", "Malmö Central".
    private static let centralWords: Set<String> = ["c", "cs", "central", "centraal", "centralstation", "centrale", "centr"]

    /// A looser name than `exactNameKey` for a station abroad: also without a trailing station word,
    /// with the short forms of "Central" alike and "oe"/"ø"/"ö" (and "ae", "ue", "aa") spelt alike, as DB
    /// writes "Broenderslev" and feeds "Brønderslev St.".
    static func looseNameKey(_ name: String) -> String {
        var text = withoutCountryMark(Station.displayName(for: name))
        for (from, to) in [("ł", "l"), ("Ł", "L"), ("ø", "o"), ("Ø", "O"), ("æ", "a"), ("Æ", "A")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = text.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        for (from, to) in [("oe", "o"), ("ae", "a"), ("ue", "u"), ("aa", "a")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        var words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        words = words.map { centralWords.contains($0) ? "central" : $0 }
        if words.count > 1, let last = words.last, trailingStationWords.contains(last) { words.removeLast() }
        return words.joined()
    }

    /// Rough borders (south, north, west, east) of the countries a code's second letter stands for
    /// ("XS…" Switzerland): a station is only matched loosely inside its country, as towns abroad share
    /// names ("Neustadt"). Countries not listed are matched by exact name only.
    private static let countryBounds: [Character: (south: Double, north: Double, west: Double, east: Double)] = [
        "A": (46.3, 49.1, 9.5, 17.2), "S": (45.8, 47.9, 5.9, 10.6), "B": (49.4, 51.6, 2.5, 6.5),
        "N": (50.7, 53.7, 3.3, 7.3), "F": (41.3, 51.2, -5.3, 9.7), "I": (36.6, 47.1, 6.6, 18.6),
        "P": (49.0, 54.9, 14.1, 24.2), "T": (48.5, 51.1, 12.0, 18.9), "D": (54.5, 57.8, 8.0, 15.3),
        "L": (49.4, 50.2, 5.7, 6.6), "V": (55.3, 69.1, 10.9, 24.2), "O": (57.9, 71.2, 4.5, 31.2),
        "H": (59.8, 70.1, 20.5, 31.6), "M": (45.7, 48.6, 16.1, 22.9),
    ]

    /// True if `coordinate` lies in the country `code` (a station abroad's) stands for.
    static func isInCountry(of code: String, _ coordinate: Coordinate) -> Bool {
        guard let country = code.first.flatMap({ $0 == "X" ? code.dropFirst().first : nil }),
              let bounds = countryBounds[country] else { return false }
        return coordinate.latitude >= bounds.south && coordinate.latitude <= bounds.north
            && coordinate.longitude >= bounds.west && coordinate.longitude <= bounds.east
    }

    /// The names of a stop compared with a station abroad's.
    struct StopKeys {
        let exact: String
        let loose: String
        init(_ name: String) {
            exact = Ril100.exactNameKey(name)
            loose = Ril100.looseNameKey(name)
        }
    }

    /// How far `station` is from `entry` if it is that station: within `matchRadius` of one of its
    /// positions with one name part of the other ("Alexanderplatz" in "Berlin Alexanderplatz",
    /// "Hamburg Hbf" in "Hamburg Hbf (S-Bahn)"), or right at it; nil otherwise. A station abroad has
    /// no positions: it counts at distance 0 when the names are the same, at distance 1 when they are
    /// alike (`looseNameKey`) and the stop lies in the station's country.
    static func distance(of station: Station, to entry: Entry, keys: StopKeys? = nil) -> Double? {
        if entry.isAbroad {
            let keys = keys ?? StopKeys(station.name)
            if !keys.exact.isEmpty, entry.abroadNameKeys.contains(keys.exact) { return 0 }
            if !keys.loose.isEmpty, entry.abroadLooseKeys.contains(keys.loose),
               let coordinate = station.coordinate, isInCountry(of: entry.code, coordinate) { return 1 }
            return nil
        }
        guard let coordinate = station.coordinate else { return nil }
        // Roughly `matchRadius` in degrees, so most points are skipped without the haversine.
        let near = entry.points.filter {
            abs($0.latitude - coordinate.latitude) < 0.006 && abs($0.longitude - coordinate.longitude) < 0.01
        }
        guard let distance = near.map(coordinate.distance(to:)).min(), distance < matchRadius else { return nil }
        return distance < sameSpotRadius || isNamed(station.name, like: entry) ? distance : nil
    }

    /// True if one name is part of the other, as `nameKey`s.
    static func isNamed(_ name: String, like entry: Entry) -> Bool {
        let key = nameKey(name), entryKey = entry.nameKey
        return !key.isEmpty && !entryKey.isEmpty && (key.contains(entryKey) || entryKey.contains(key))
    }

    /// True if `station` is `entry`'s station (or one of its levels).
    public static func matches(_ station: Station, _ entry: Entry) -> Bool {
        distance(of: station, to: entry) != nil
    }

    /// The code shown next to `station`: of the codes it matches, the shortest – a station's levels
    /// have longer ones ("FF" before "FFT", "BL" before "BLS") – then the nearest. A match by position
    /// beats one by name alone.
    public static func code(for station: Station) -> String? {
        entry(for: station, in: all)?.code
    }

    /// `code(for:)` of each station, by its ID, worked out off the calling thread: the first lookup
    /// waits for the list to load and each goes through all of it, which held up the picker's main
    /// thread for half a second on the first search after launch (#301).
    public static func codes(for stations: [Station]) async -> [String: String] {
        await Task.detached(priority: .userInitiated) {
            stations.reduce(into: [:]) { codes, station in codes[station.id] = code(for: station) }
        }.value
    }

    static func entry(for station: Station, in entries: [Entry]) -> Entry? {
        let keys = StopKeys(station.name)
        // By position first; abroad the same name before a similar one, then the shortest code.
        func order(_ match: (entry: Entry, distance: Double)) -> (Int, Double, Int, Double) {
            match.entry.isAbroad ? (1, match.distance, match.entry.code.count, 0) : (0, 0, match.entry.code.count, match.distance)
        }
        return entries.compactMap { entry in distance(of: station, to: entry, keys: keys).map { (entry: entry, distance: $0) } }
            .min { order($0) < order($1) }?.entry
    }

    /// Search hits for the code `entry` was found by: `hit` (the station looked up by DB's name) first,
    /// and every other hit that is the same station left out, so it shows up once (#165). Behind the
    /// first hit, though, when its name starts with what was typed as a word: "Aha" is a station and
    /// Harblek's code, "bad" Altdöbern's and the start of every "Bad …" (but "Canyon MHP" doesn't
    /// push back München Heimeranplatz).
    static func placing(_ hit: Station?, for entry: Entry, typed text: String, in stations: [Station]) -> [Station] {
        var hit = hit
        var rest: [Station] = []
        for station in stations {
            if matches(station, entry) {
                if hit == nil { hit = station }
            } else {
                rest.append(station)
            }
        }
        guard let hit else { return stations }
        let typed = Station.normalize(text)
        let firstWord = rest.first?.displayName.split { !$0.isLetter && !$0.isNumber }.first.map { Station.normalize(String($0)) }
        rest.insert(hit, at: firstWord == typed ? 1 : 0)
        return rest
    }
}
