import Foundation

/// DB's RIL100 station codes ("FF" Frankfurt (Main) Hbf, "AH" Hamburg Hbf), from the offline list
/// `Resources/Ril100.json` built by `scripts/make-ril100.py` (DB Station&Service, CC BY 4.0) (#165).
/// Station search finds a station by any of its codes, typed in any case; the picker can show a
/// station's main code next to its name. Transitous' stops carry no EVA number, so they're matched
/// to the list by position and name.
public enum Ril100 {
    public struct Entry: Decodable, Sendable, Hashable {
        /// DB's name, e.g. "Berlin Hauptbahnhof".
        public let name: String
        public let coordinate: Coordinate
        /// Every code of the station, the main one first ("BHBF", "BL", "BLS").
        public let codes: [String]
        public let evaNumber: String

        /// The code shown next to the station.
        public var code: String { codes[0] }

        init(name: String, coordinate: Coordinate, codes: [String], evaNumber: String) {
            self.name = name
            self.coordinate = coordinate
            self.codes = codes
            self.evaNumber = evaNumber
        }

        public init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            name = try row.decode(String.self)
            coordinate = Coordinate(latitude: try row.decode(Double.self), longitude: try row.decode(Double.self))
            codes = try row.decode([String].self)
            evaNumber = try row.decode(String.self)
        }

        var nameKey: String { Ril100.nameKey(name) }
    }

    static let all: [Entry] = {
        guard let url = Bundle.module.url(forResource: "Ril100", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    private static let byCode: [String: Entry] = index(all)

    static func index(_ entries: [Entry]) -> [String: Entry] {
        var index: [String: Entry] = [:]
        for entry in entries {
            for code in entry.codes { index[codeKey(code)] = index[codeKey(code)] ?? entry }
        }
        return index
    }

    /// Upper case with single spaces, as codes like "TU  F" are written with two.
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

    /// A station's name without "Hbf" and the parts in brackets: "Frankfurt (Main) Hbf" → "Frankfurt".
    static func townName(_ name: String) -> String {
        var town = Station.displayName(for: name)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        town = town.split(separator: " ").filter { $0 != "Hbf" }.joined(separator: " ")
        return town.isEmpty ? name : town
    }

    /// The station whose code is exactly what was typed, in any case: "ff" → Frankfurt (Main) Hbf.
    public static func entry(forCode text: String) -> Entry? {
        entry(forCode: text, in: byCode)
    }

    static func entry(forCode text: String, in index: [String: Entry]) -> Entry? {
        let key = codeKey(text)
        guard (2...6).contains(key.count) else { return nil }
        return index[key]
    }

    /// How far a stop may be from DB's position of the station and still count as it: Hamburg Hbf's
    /// S-Bahn platforms or Berlin Hbf's lower level are a few hundred metres off.
    static let matchRadius: Double = 600

    /// Nearer than this, a stop counts as the station whatever it's called ("Frankfurt(M) Hbf").
    static let sameSpotRadius: Double = 80

    /// The station `station` is: by EVA number if it has one, else the nearest within `matchRadius`
    /// whose name is part of the stop's or the other way round ("Alexanderplatz" in
    /// "Berlin Alexanderplatz", "Hamburg Hbf" in "Hamburg Hbf (S-Bahn)"), or one right at the stop.
    public static func entry(for station: Station) -> Entry? {
        entry(for: station, in: all)
    }

    static func entry(for station: Station, in entries: [Entry]) -> Entry? {
        if let eva = station.evaNumber, let entry = entries.first(where: { $0.evaNumber == eva }) { return entry }
        guard let coordinate = station.coordinate else { return nil }
        let key = nameKey(station.name)
        // Roughly `matchRadius` in degrees, so most entries are skipped without the haversine.
        let latSpan = 0.006, lonSpan = 0.01
        var best: (entry: Entry, distance: Double)?
        for entry in entries
            where abs(entry.coordinate.latitude - coordinate.latitude) < latSpan
            && abs(entry.coordinate.longitude - coordinate.longitude) < lonSpan
        {
            let distance = coordinate.distance(to: entry.coordinate)
            guard distance < matchRadius, distance < best?.distance ?? .infinity else { continue }
            let entryKey = entry.nameKey
            let namesMatch = !key.isEmpty && !entryKey.isEmpty && (key.contains(entryKey) || entryKey.contains(key))
            if namesMatch || distance < sameSpotRadius { best = (entry, distance) }
        }
        return best?.entry
    }

    /// The main code shown next to `station`, e.g. "FF".
    public static func code(for station: Station) -> String? {
        entry(for: station)?.code
    }

    /// Search hits for the code `entry` was found by: `hit` (the station looked up by DB's name) first,
    /// and every other hit that is the same station left out, so it shows up once (#165). Behind the
    /// first hit, though, when its name starts with what was typed as a word: "Aha" is a station and
    /// Harblek's code, "bad" Altdöbern's and the start of every "Bad …" (but "Canyon MHP" doesn't
    /// push back München-Heimeranplatz).
    static func placing(_ hit: Station?, for entry: Entry, typed text: String, in stations: [Station],
                        entries: [Entry] = all) -> [Station]
    {
        var hit = hit
        var rest: [Station] = []
        for station in stations {
            if self.entry(for: station, in: entries)?.evaNumber == entry.evaNumber {
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
