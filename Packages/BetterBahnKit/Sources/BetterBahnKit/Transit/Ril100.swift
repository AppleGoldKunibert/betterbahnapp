import Foundation

/// DB's RIL100 station codes ("FF" Frankfurt (Main) Hbf, "AH" Hamburg Hbf), from the offline list
/// `Resources/Ril100.json` built by `scripts/make-ril100.py` from DB InfraGO's operating points
/// (Deutsche Bahn AG, CC BY 4.0) (#165). Station search finds a station by its code, typed in any
/// case; the picker can show a station's code next to its name. DB's list has no EVA numbers, so
/// stops are matched to codes by position and name.
public enum Ril100 {
    public struct Entry: Decodable, Sendable, Hashable {
        /// E.g. "FF", or "LL T" for Leipzig Hbf's lower level.
        public let code: String
        /// DB's name, e.g. "Berlin Hauptbahnhof - Lehrter Bahnhof".
        public let name: String
        /// Where the station lies on each of its lines: a big one spans kilometres.
        public let points: [Coordinate]

        init(code: String, name: String, points: [Coordinate]) {
            self.code = code
            self.name = name
            self.points = points
        }

        public init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            code = try row.decode(String.self)
            name = try row.decode(String.self)
            let flat = try row.decode([Double].self)
            points = stride(from: 0, to: flat.count - 1, by: 2).map { Coordinate(latitude: flat[$0], longitude: flat[$0 + 1]) }
        }

        var nameKey: String { Ril100.nameKey(name) }
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

    /// How far `station` is from `entry` if it is that station: within `matchRadius` of one of its
    /// positions with one name part of the other ("Alexanderplatz" in "Berlin Alexanderplatz",
    /// "Hamburg Hbf" in "Hamburg Hbf (S-Bahn)"), or right at it; nil otherwise.
    static func distance(of station: Station, to entry: Entry) -> Double? {
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
    /// have longer ones ("FF" before "FFT", "BL" before "BLS") – then the nearest.
    public static func code(for station: Station) -> String? {
        entry(for: station, in: all)?.code
    }

    static func entry(for station: Station, in entries: [Entry]) -> Entry? {
        entries.compactMap { entry in distance(of: station, to: entry).map { (entry, $0) } }
            .min { ($0.0.code.count, $0.1) < ($1.0.code.count, $1.1) }?.0
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
