import Foundation

/// DB's RIL100 station codes ("FF" Frankfurt (Main) Hbf, "AH" Hamburg Hbf), from the offline list
/// `Resources/Ril100.json` built by `scripts/make-ril100.py` from DB InfraGO's operating points
/// (Deutsche Bahn AG, CC BY 4.0) (#165). Station search finds a station by its code, typed in any
/// case; the picker can show a station's code next to its name. DB's list has no EVA numbers, so
/// stops are matched to codes by position and name. Stations abroad ("XS ZH" Zürich HB: X + country
/// letter, Z for eastern Europe) come from DB's other list of operating points and have no
/// positions: they are matched by their exact name.
public enum Ril100 {
    public struct Entry: Decodable, Sendable, Hashable {
        /// E.g. "FF", or "LL T" for Leipzig Hbf's lower level.
        public let code: String
        /// DB's name, e.g. "Berlin Hauptbahnhof - Lehrter Bahnhof".
        public let name: String
        /// Where the station lies on each of its lines: a big one spans kilometres. Empty for
        /// stations abroad.
        public let points: [Coordinate]

        /// What a stop abroad may be called to be this station (`isSameName`); empty with positions.
        let abroadNameKeys: Set<String>

        init(code: String, name: String, points: [Coordinate]) {
            self.code = code
            self.name = name
            self.points = points
            abroadNameKeys = points.isEmpty ? Ril100.abroadNameKeys(for: name) : []
        }

        public init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            code = try row.decode(String.self)
            name = try row.decode(String.self)
            let flat = try row.decode([Double].self)
            points = stride(from: 0, to: flat.count - 1, by: 2).map { Coordinate(latitude: flat[$0], longitude: flat[$0 + 1]) }
            abroadNameKeys = points.isEmpty ? Ril100.abroadNameKeys(for: name) : []
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
        let shown = Station.displayName(for: name)
            .replacingOccurrences(of: #" \([A-Z]{2}\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: "Ł", with: "L")
        return Station.normalize(shown.folding(options: .diacriticInsensitive, locale: nil))
    }

    /// The names a stop abroad may have to be the station `name`: the whole name, or one of the two names
    /// of a station DB gives both ("Bruxelles-Midi / Brussel-Zuid").
    static func abroadNameKeys(for name: String) -> Set<String> {
        let parts = name.components(separatedBy: " / ") + name.components(separatedBy: " - ")
        return Set(([name] + parts).map(exactNameKey).filter { !$0.isEmpty })
    }

    /// How far `station` is from `entry` if it is that station: within `matchRadius` of one of its
    /// positions with one name part of the other ("Alexanderplatz" in "Berlin Alexanderplatz",
    /// "Hamburg Hbf" in "Hamburg Hbf (S-Bahn)"), or right at it; nil otherwise. A station abroad has
    /// no positions: it counts when the names are the same, at distance 0.
    static func distance(of station: Station, to entry: Entry, nameKey: String? = nil) -> Double? {
        if entry.isAbroad { return entry.abroadNameKeys.contains(nameKey ?? exactNameKey(station.name)) ? 0 : nil }
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

    static func entry(for station: Station, in entries: [Entry]) -> Entry? {
        let key = exactNameKey(station.name)
        return entries.compactMap { entry in distance(of: station, to: entry, nameKey: key).map { (entry, $0) } }
            .min { ($0.0.isAbroad ? 1 : 0, $0.0.code.count, $0.1) < ($1.0.isAbroad ? 1 : 0, $1.0.code.count, $1.1) }?.0
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
