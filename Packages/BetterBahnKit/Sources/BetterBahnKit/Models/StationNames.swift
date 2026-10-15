import Foundation
import Synchronization

/// The names stations are shown under (#205): DB's own for German stations ("Dresden-Neustadt" for DELFI's
/// "Dresden Bahnhof Neustadt"), the national railway's with its accents for stations abroad ("Děčín hl.n." for
/// "Decin hl.n."). From the offline list `Resources/StationNames.json` built by `scripts/make-station-names.py`
/// from DB InfraGO's OpenStation data (Deutsche Bahn AG, CC0), DB's passenger names and the train stops of
/// all feeds in Transitous.
/// `Station.displayName` asks here, so journeys, boards, trips, saved journeys and widgets all agree; a
/// station's ID and `name`, and so everything matched by them, stay as the feed has them.
public enum StationNames {
    struct GermanStation: Sendable {
        /// DB's name, e.g. "Berlin Hauptbahnhof", "Bernau (b Berlin)" (shown cleaned up by `Station.displayName(for:)`).
        let name: String
        /// Where the station's RIL100 codes lie; empty for the few without one in `Ril100.json`.
        let points: [Coordinate]
        let words: NameWords
        /// Its EVA numbers, sorted, so the main station's comes first ("8011160" before Berlin Hbf's lower
        /// level "8098160").
        var evas: [String] = []
    }

    /// A train stop of another railway's feed that is this German station under another name, e.g.
    /// SNCF's "Munich" or European Sleeper's "Berlin Ostbf", where it lies.
    struct Alias: Sendable {
        let coordinate: Coordinate
        let station: Int
    }

    struct StationAbroad: Sendable {
        /// The national railway's name, e.g. "Děčín hlavní nádraží".
        let name: String
        let coordinate: Coordinate
    }

    struct Index: Sendable {
        var stations: [GermanStation] = []
        var byDHID: [String: Int] = [:]
        var byEVA: [String: Int] = [:]
        /// Stations by `cell(of:)` of each of their points.
        var cells: [Int: [Int]] = [:]
        /// Stations abroad by `abroadKey`.
        var abroad: [String: [StationAbroad]] = [:]
        /// Other railways' names of German stations by `aliasKey`.
        var aliases: [String: [Alias]] = [:]
    }

    private struct File: Decodable {
        struct German: Decodable {
            let dhid: String, name: String, evas: [String], points: [Coordinate]

            init(from decoder: any Decoder) throws {
                var row = try decoder.unkeyedContainer()
                dhid = try row.decode(String.self)
                name = try row.decode(String.self)
                evas = try row.decode([String].self)
                let flat = try row.decode([Double].self)
                points = stride(from: 0, to: flat.count - 1, by: 2).map { Coordinate(latitude: flat[$0], longitude: flat[$0 + 1]) }
            }
        }

        struct Abroad: Decodable {
            let name: String, coordinate: Coordinate

            init(from decoder: any Decoder) throws {
                var row = try decoder.unkeyedContainer()
                name = try row.decode(String.self)
                coordinate = Coordinate(latitude: try row.decode(Double.self), longitude: try row.decode(Double.self))
            }
        }

        struct AliasRow: Decodable {
            let name: String, coordinate: Coordinate, station: Int

            init(from decoder: any Decoder) throws {
                var row = try decoder.unkeyedContainer()
                name = try row.decode(String.self)
                coordinate = Coordinate(latitude: try row.decode(Double.self), longitude: try row.decode(Double.self))
                station = try row.decode(Int.self)
            }
        }

        let germany: [German]
        let abroad: [Abroad]
        let aliases: [AliasRow]?
    }

    static let index: Index = {
        guard let url = Bundle.module.url(forResource: "StationNames", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return Index() }
        return makeIndex(germany: file.germany.map { ($0.dhid, $0.name, $0.evas, $0.points) },
                         abroad: file.abroad.map { ($0.name, $0.coordinate) },
                         aliases: (file.aliases ?? []).map { ($0.name, $0.coordinate, $0.station) })
    }()

    static func makeIndex(germany: [(dhid: String, name: String, evas: [String], points: [Coordinate])],
                          abroad: [(name: String, coordinate: Coordinate)],
                          aliases: [(name: String, coordinate: Coordinate, station: Int)] = []) -> Index {
        var index = Index()
        for station in germany {
            let number = index.stations.count
            index.stations.append(GermanStation(name: station.name, points: station.points, words: nameWords(station.name),
                                                evas: station.evas))
            if !station.dhid.isEmpty { index.byDHID[station.dhid] = number }
            for eva in station.evas where index.byEVA[eva] == nil { index.byEVA[eva] = number }
            for cell in Set(station.points.map(cell(of:))) { index.cells[cell, default: []].append(number) }
        }
        for station in abroad {
            let key = abroadKey(station.name)
            guard !key.isEmpty else { continue }
            index.abroad[key, default: []].append(StationAbroad(name: station.name, coordinate: station.coordinate))
        }
        for alias in aliases where index.stations.indices.contains(alias.station) {
            index.aliases[aliasKey(alias.name), default: []].append(Alias(coordinate: alias.coordinate, station: alias.station))
        }
        return index
    }

    /// Loads the list off the calling thread, so the first name shown doesn't wait for it.
    public static func preload() async {
        await Task.detached(priority: .utility) { _ = index }.value
    }

    /// The name `station` is shown under before `Station.displayName(for:)` tidies it: DB's for a German
    /// station, the national railway's for one abroad, nil to keep the feed's.
    static func name(for station: Station) -> String? {
        let key = "\(station.id)|\(station.name)"
        if let known = cache.withLock({ $0[key] }) { return known }
        let found = name(for: station, in: index)
        cache.withLock { names in
            if names.count >= cacheLimit { names.removeAll(keepingCapacity: true) }
            names[key] = found
        }
        return found
    }

    /// `station`'s EVA number from the offline list, so it needn't be asked from bahn.de. Only for a station
    /// with a single one: of a station with several levels (Berlin Hbf, Frankfurt (Main) Hbf), the stop may be
    /// on either, which only bahn.de's search by the stop's own name tells.
    public static func evaNumber(for station: Station) -> String? {
        evaNumber(for: station, in: index)
    }

    static func evaNumber(for station: Station, in index: Index) -> String? {
        guard let number = germanStation(for: station, in: index) else { return nil }
        let evas = index.stations[number].evas
        return evas.count == 1 ? evas[0] : nil
    }

    static func name(for station: Station, in index: Index) -> String? {
        if let number = germanStation(for: station, in: index) { return index.stations[number].name }
        return nameAbroad(for: station.name, near: station.coordinate, in: index)
    }

    /// Names already looked up by stop ID and feed name: views ask for the same stations' names over and over.
    private static let cache = Mutex<[String: String?]>([:])
    private static let cacheLimit = 5_000

    /// A station known only by its name (a headsign, a train's ends in bahn.expert's list) and maybe its
    /// EVA number, as shown: DB's name by the EVA number, else with the accents of a station abroad whose
    /// name has them alike everywhere ("Praha-Holešovice" for "Praha-Holesovice").
    public static func displayName(forName name: String, evaNumber: String? = nil) -> String {
        if let evaNumber, let number = index.byEVA[evaNumber] { return Station.displayName(for: index.stations[number].name) }
        return Station.displayName(for: nameAbroad(for: name, near: nil, in: index) ?? name)
    }

    // MARK: Germany

    /// How far a stop under the station's name may be from one of its positions (on its lines, from
    /// `Ril100.json`) and still be it.
    static let matchRadius: Double = 600

    /// How far a stop may be from the station when only the names' brackets differ ("Stade(Niederelbe)" for
    /// "Stade"): further away it can be the twin town across the border, SBB's Laufenburg for Laufenburg (Baden).
    static let coreMatchRadius: Double = 300

    /// How far a stop named with only a part of the station's name may be from it ("Mergelstetten" for
    /// "Heidenheim-Mergelstetten"): such a stop further away is more likely a bus stop named after it.
    static let partialMatchRadius: Double = 150

    /// How far a stop may be from where another railway's feed has the station under that name.
    static let aliasRadius: Double = 150

    /// DB's station for `station`: by the DHID in its ID (DELFI's and most German feeds' stop areas,
    /// "de-DELFI_de:14612:16" is Dresden-Neustadt), by its EVA number (bahn.de's), by another railway's
    /// name for it at that place (SNCF's "Munich", `Alias`), else nearby under the same name (PKP's "S+U
    /// Lichtenberg Bhf (Berlin)" is Berlin-Lichtenberg, VBN's "Stade(Niederelbe)" Stade, "Hildesheim
    /// Ostbahnhof" Hildesheim Ost) or close by under a part of it. A stop named more than the station
    /// ("Hauptbahnhof (U, Tram)", "Heilbronn Hbf/Willy-Brandt-Platz") isn't it.
    static func germanStation(for station: Station, in index: Index) -> Int? {
        if let dhid = dhid(in: station.id), let number = index.byDHID[dhid] { return number }
        if let eva = station.evaNumber, let number = index.byEVA[eva] { return number }
        guard let coordinate = station.coordinate else { return nil }
        if let alias = index.aliases[aliasKey(station.name)]?
            .map({ ($0.station, $0.coordinate.distance(to: coordinate)) })
            .filter({ $0.1 < aliasRadius }).min(by: { $0.1 < $1.1 }) {
            return alias.0
        }
        let center = cell(of: coordinate)
        let nearby = Set((-1...1).flatMap { dy in (-1...1).flatMap { dx in index.cells[center + dy * cellRow + dx] ?? [] } })
        guard !nearby.isEmpty else { return nil }
        let words = nameWords(station.name)
        guard !words.all.isEmpty else { return nil }
        return nearby.compactMap { number -> (number: Int, distance: Double)? in
            let candidate = index.stations[number].words
            let radius = words.all == candidate.all ? matchRadius
                : !words.core.isEmpty && words.core == candidate.core ? coreMatchRadius
                : words.all.isSubset(of: candidate.all) ? partialMatchRadius : 0
            guard let distance = index.stations[number].points.map(coordinate.distance(to:)).min(),
                  distance < radius else { return nil }
            return (number, distance)
        }
        .min { ($0.distance, $0.number) < ($1.distance, $1.number) }?.number
    }

    /// A feed's name as `Alias`es are looked up: `folded`, only letters and digits.
    static func aliasKey(_ name: String) -> String {
        folded(name).filter { $0.isLetter || $0.isNumber }
    }

    /// The stop area's DHID in a stop ID, as `scripts/make-station-names.py` writes it: "de:14612:16" in
    /// "de-DELFI_de:14612:16", "de-DELFI_de:14628:3620:5:Gleis3" or "…_de:11000:900003200:1:51";
    /// "de:08135:620" in "de-DELFI_de:08135:0620".
    static func dhid(in id: String) -> String? {
        guard let start = id.range(of: "de:") else { return nil }
        if start.lowerBound != id.startIndex {
            let before = id[id.index(before: start.lowerBound)]
            guard before == "_" || before == ":" else { return nil }
        }
        let parts = id[start.upperBound...].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].count == 5, parts[0].allSatisfy(\.isNumber),
              let stop = Int(parts[1]) else { return nil }
        return "de:\(parts[0]):\(stop)"
    }

    /// Words feeds add to a station's name that say nothing about which one it is.
    private static let stationWords: Set<String> = [
        "bahnhof", "bf", "bhf", "station", "central", "gare", "flixtrain", "hp",
    ]

    /// The words of a name as compared with a station's.
    struct NameWords: Sendable, Equatable {
        /// Every word, also those in brackets.
        let all: Set<String>
        /// The words outside brackets ("Stade(Niederelbe)" → stade), unless the brackets say the stop is
        /// something else than the station ("Hauptbahnhof (U, Tram)", "Kehl (Gr)"): then all of them.
        let core: Set<String>
    }

    /// Bracketed words saying a stop is something else than the station: another mode's or a border point.
    private static let ownStopWords: Set<String> = [
        "u", "s", "tram", "bus", "zob", "strab", "hsb", "ubahn", "sbahn", "stadtbahn", "gr", "grenze",
    ]

    /// The words of a name as shown, for comparing a stop with a station: umlauts spelt out or not
    /// ("Woerth" is "Wörth"), without `stationWords`, and "…bahnhof" or "…bf" as what it is short of,
    /// since DB names a town's "Ostbahnhof" "… Ost" ("Hildesheim Ost") and European Sleeper writes
    /// "Berlin Ostbf". "Frankfurt (Main) Hauptbahnhof" → frankfurt, main, hbf; "S+U Lichtenberg Bhf
    /// (Berlin)" → berlin, lichtenberg; "Hauptbahnhof (U, Tram)" keeps u, tram.
    static func nameWords(_ name: String) -> NameWords {
        // FlixTrain's "Dortmund Central Station (FlixTrain)" is Dortmund Hbf.
        let shown = folded(Station.displayName(for: name)).replacingOccurrences(of: "central station", with: "hbf")
        let all = words(in: shown)
        let core = words(in: shown.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression))
        return NameWords(all: all, core: all.subtracting(core).isDisjoint(with: ownStopWords) ? core : all)
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.split { !$0.isLetter && !$0.isNumber }.map { word -> String in
            if word.count > 7, word.hasSuffix("bahnhof") { return String(word.dropLast(7)) }
            if word.count > 3, word.hasSuffix("bf") { return String(word.dropLast(2)) }
            return String(word)
        }.map { $0 == "haupt" ? "hbf" : $0 }.filter { !$0.isEmpty && !stationWords.contains($0) })
    }

    /// Lower case without accents, "ß" as "ss" and "ö"/"oe", "ä"/"ae", "ü"/"ue", "å"/"aa" alike: "Wörth"
    /// and "Woerth" are both "worth", "København" and "Koebenhavn" both "kobenhavn".
    static func folded(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "ß", with: "ss")
        for (from, to) in [("ł", "l"), ("Ł", "L"), ("ø", "o"), ("Ø", "O"), ("æ", "ae"), ("Æ", "Ae"), ("đ", "d"), ("Đ", "D")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for (from, to) in [("oe", "o"), ("ae", "a"), ("ue", "u"), ("aa", "a")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    /// Grid cells of 0.01° (about 1.1 km north–south, 0.7 km east–west in Germany), so a stop's own cell
    /// and the eight around it hold every station within `matchRadius`.
    static func cell(of coordinate: Coordinate) -> Int {
        Int((coordinate.latitude * 100).rounded()) * cellRow + Int((coordinate.longitude * 100).rounded())
    }

    private static let cellRow = 100_000

    // MARK: Abroad

    /// How far a stop abroad may be from the national railway's station of the same name and still be it.
    static let abroadRadius: Double = 3_000

    /// The national railway's name for the station abroad called `name` (spelt without accents or as the
    /// national railway does): the one of that name nearest `coordinate` within `abroadRadius`, or,
    /// without a position, the one name every station of that name has. Kolín and Polish Kolin are
    /// both "kolin", so DELFI's "Kolin(CZ)" needs its position.
    static func nameAbroad(for name: String, near coordinate: Coordinate?, in index: Index) -> String? {
        guard let candidates = index.abroad[abroadKey(name)] else { return nil }
        guard let coordinate else {
            let names = Set(candidates.map(\.name))
            return names.count == 1 ? names.first : nil
        }
        return candidates.map { ($0.name, $0.coordinate.distance(to: coordinate)) }
            .filter { $0.1 < abroadRadius }
            .min { $0.1 < $1.1 }?.0
    }

    /// A station abroad's name as compared: shortened as shown ("Děčín hlavní nádraží" is "Děčín hl.n."),
    /// without a country mark ("Kolin (CZ)") and `folded`, only letters and digits: "decinhln".
    static func abroadKey(_ name: String) -> String {
        let shown = Ril100.withoutCountryMark(Station.displayName(for: name))
        return folded(shown).filter { $0.isLetter || $0.isNumber }
    }
}
