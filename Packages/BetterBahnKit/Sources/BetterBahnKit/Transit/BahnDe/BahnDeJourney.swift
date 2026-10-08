import Foundation

/// One stop of a journey's realtime course, as bahn.de's journey details (`reiseloesung/fahrt`)
/// report it — the only source in this app that carries a Zusatzhalt (an unscheduled stop a train
/// additionally picked up, e.g. after a diversion) or a stop it skipped, since Transitous and
/// Träwelling's own trip data only carry the planned schedule.
public struct JourneyStop: Sendable, Hashable {
    public var evaNumber: String
    public var name: String
    public var coordinate: Coordinate?
    public var arrival: TimeInfo?
    public var departure: TimeInfo?
    public var arrivalPlatform: PlatformInfo?
    public var departurePlatform: PlatformInfo?
    public var isAdditional: Bool
    public var isCancelled: Bool

    public init(evaNumber: String, name: String, coordinate: Coordinate? = nil, arrival: TimeInfo? = nil, departure: TimeInfo? = nil,
                arrivalPlatform: PlatformInfo? = nil, departurePlatform: PlatformInfo? = nil,
                isAdditional: Bool = false, isCancelled: Bool = false) {
        self.evaNumber = evaNumber
        self.name = name
        self.coordinate = coordinate
        self.arrival = arrival
        self.departure = departure
        self.arrivalPlatform = arrivalPlatform
        self.departurePlatform = departurePlatform
        self.isAdditional = isAdditional
        self.isCancelled = isCancelled
    }
}

/// A railway undertaking running (part of) a train, as bahn.de lists it. International trains are run by
/// several, one per section, e.g. Berlin → Praha by DB Fernverkehr in Germany and České dráhy in Czechia.
public struct TrainOperator: Sendable, Hashable {
    public struct Section: Sendable, Hashable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public var name: String
    /// First and last station of its section, as bahn.de names them; `nil` when it runs the whole train.
    public var section: Section?

    public init(name: String, section: Section? = nil) {
        self.name = name
        self.section = section
    }
}

extension Stopover {
    /// A `Stopover` for a Zusatzhalt bahn.de reported (see `BahnDeClient.inserting(_:into:)`). Only
    /// ever used for display; a Zusatzhalt's Träwelling checkin goes through
    /// `TraewellingClient.checkin(_:fromZusatzhalt:toNextRegularStop:)`, not through this station.
    init(_ stop: JourneyStop) {
        self.init(station: Station(id: "bahnde:\(stop.evaNumber)", name: stop.name, coordinate: stop.coordinate,
                                   evaNumber: stop.evaNumber, source: .bahnDe),
                  arrival: stop.arrival, departure: stop.departure,
                  arrivalPlatform: stop.arrivalPlatform, departurePlatform: stop.departurePlatform,
                  cancelled: false, isAdditional: true)
    }
}

extension BahnDeClient {
    // MARK: Wire types

    struct Board: Decodable {
        struct Entry: Decodable {
            struct Transport: Decodable { var name: String?; var mittelText: String?; var produktGattung: String? }
            var journeyId: String
            /// Scheduled departure, Berlin local time without zone, e.g. "2026-09-29T22:38:00".
            var zeit: String?
            /// DB's live time, same format; missing when DB has none for the train.
            var ezZeit: String?
            var verkehrmittel: Transport?
            /// Destination (departures) or origin (arrivals), e.g. "Berlin-Frohnau".
            var terminus: String?
        }
        var entries: [Entry]
    }

    struct JourneyDetails: Decodable {
        struct Stop: Decodable {
            /// Newer responses nest the times per event.
            struct Event: Decodable { var sollzeit: String?; var echtzeit: String? }
            struct Message: Decodable { var type: String?; var text: String? }
            struct RISMessage: Decodable { var key: String? }
            /// HAFAS location ID, e.g. "A=1@O=Frankfurt(Main)Hbf@X=8663785@Y=50107149@L=8000105@".
            var id: String?
            var extId: String?
            var evaNumber: String?
            var name: String
            var gleis: String?
            var ezGleis: String?
            var canceled: Bool?
            var additional: Bool?
            var abfahrt: Event?
            var ankunft: Event?
            var abfahrtsZeitpunkt: String?
            var ezAbfahrtsZeitpunkt: String?
            var ankunftsZeitpunkt: String?
            var ezAnkunftsZeitpunkt: String?
            var priorisierteMeldungen: [Message]?
            var risMeldungen: [RISMessage]?
            /// The railway running the train from this stop, by its UIC code: RJ 171 has "80" (DB) from
            /// Hamburg-Altona to Bad Schandau and "54" (ČD) from Děčín to Praha hl.n.
            var adminID: String?
            /// The train's category here, e.g. "RJ".
            var kategorie: String?
        }
        /// The train's attributes; operators may come as "BEF" (Beförderer) entries, one per section on
        /// trains run by several, e.g. `{"key": "BEF", "value": "DB Fernverkehr AG",
        /// "teilstreckenHinweis": "(Berlin Hbf - Bad Schandau)"}` (as parsed by db-vendo-client). The
        /// journey details of RJ 171 Hamburg → Praha (2026-10-07) had none, only each stop's `adminID`.
        struct Attribute: Decodable { var kategorie: String?; var key: String?; var value: String?; var teilstreckenHinweis: String? }
        var halte: [Stop]
        var zugattribute: [Attribute]?
        /// The train's name, e.g. "RJ 383".
        var zugName: String?

        /// The attributes list sleeping ("Schlafwagen", SW) or couchette cars ("Liegewagen", LW): a night
        /// train, also one the timetable feeds don't mark (#241), e.g. Snälltåget's "D 301".
        var hasSleepingCars: Bool {
            zugattribute?.contains { $0.kategorie == "SCHLAFWAGEN" || ["SW", "LW"].contains($0.key) } == true
        }
    }

    /// A train's journey details: its realtime stops, the operators running it and whether it has sleepers.
    struct JourneyCourse: Sendable {
        var stops: [JourneyStop]
        var operators: [TrainOperator]
        var hasSleepingCars = false
    }

    // MARK: Journey stops

    /// The realtime stop sequence for `leg`'s train, including any Zusatzhalt (unscheduled stop) or
    /// stop it skipped — data Transitous doesn't carry at all (see `TimetablesClient` for the same gap
    /// on delays/platforms) since it only ever has the planned schedule. `nil` if `leg`'s train is
    /// neither a DB long-distance train nor a regional train with a run number (`journeyReference`);
    /// throws `TransitError.notFound` if bahn.de doesn't list it.
    /// `maxAge` is how old a cached answer may be; legs days ahead can do with an hourly look.
    public func journeyStops(for leg: Leg, maxAge: TimeInterval = BahnDeClient.journeyStopsMaxAge) async throws -> [JourneyStop]? {
        try await journeyStops(line: leg.line, station: leg.origin, plannedDeparture: leg.departure.planned, maxAge: maxAge)
    }

    /// The realtime stop sequence for `trip`'s train (see `journeyStops(for:)` above); `nil` under the
    /// same conditions, plus when `trip` has no departing stop to look the train up at.
    public func journeyStops(for trip: Trip) async throws -> [JourneyStop]? {
        guard let first = trip.stopovers.first(where: { $0.departure != nil }), let departure = first.departure else { return nil }
        return try await journeyStops(line: trip.line, station: first.station, plannedDeparture: departure.planned)
    }

    private func journeyStops(line: Line?, station: Station, plannedDeparture: Date,
                              maxAge: TimeInterval = BahnDeClient.journeyStopsMaxAge) async throws -> [JourneyStop]? {
        try await journeyCourse(line: line, station: station, plannedDeparture: plannedDeparture, maxAge: maxAge)?.stops
    }

    /// `journeyStops(for:)` together with the rest of bahn.de's journey details, same request and cache.
    func journeyCourse(for leg: Leg, maxAge: TimeInterval = BahnDeClient.journeyStopsMaxAge) async throws -> JourneyCourse? {
        try await journeyCourse(line: leg.line, station: leg.origin, plannedDeparture: leg.departure.planned, maxAge: maxAge)
    }

    /// Whether bahn.de lists sleeping or couchette cars for `trip`'s train (`JourneyDetails.hasSleepingCars`);
    /// shares the request and cache of `journeyStops(for:)`.
    public func hasSleepingCars(for trip: Trip) async throws -> Bool {
        guard let first = trip.stopovers.first(where: { $0.departure != nil }), let departure = first.departure,
              let course = try await journeyCourse(line: trip.line, station: first.station, plannedDeparture: departure.planned)
        else { return false }
        return course.hasSleepingCars
    }

    /// `leg` marked as a night train when bahn.de's journey details list sleeping or couchette cars.
    static func markingNightTrain(_ leg: Leg, hasSleepingCars: Bool) -> Leg {
        guard hasSleepingCars, leg.line?.isNightTrain == false else { return leg }
        var leg = leg
        leg.line?.nightRail = true
        return leg
    }

    /// The operators bahn.de lists for the part of `leg`'s train you ride: on an international train run
    /// by several (one per section), only those whose section overlaps the leg. `nil` under the same
    /// conditions as `journeyStops(for:)` or when bahn.de names none; shares its request and cache.
    public func trainOperators(for leg: Leg) async throws -> [TrainOperator]? {
        guard let course = try await journeyCourse(line: leg.line, station: leg.origin, plannedDeparture: leg.departure.planned) else { return nil }
        let operators = Self.operators(course.operators, riding: leg, stops: course.stops)
        return operators.isEmpty ? nil : operators
    }

    /// Every operator bahn.de lists for `trip`'s train, each with its section when there are several.
    public func trainOperators(for trip: Trip) async throws -> [TrainOperator]? {
        guard let first = trip.stopovers.first(where: { $0.departure != nil }), let departure = first.departure,
              let course = try await journeyCourse(line: trip.line, station: first.station, plannedDeparture: departure.planned)
        else { return nil }
        switch course.operators.count {
        case 0: return nil
        case 1: return [TrainOperator(name: course.operators[0].name)]
        default: return course.operators
        }
    }

    /// Where a train run by several railways changes hands, for marking those stops in its route:
    /// stopover ID → the operators to show there. RJ 171: DB at its first stop and at Bad Schandau,
    /// ČD at Děčín. Empty for a train run by one railway; shares the request and cache of `journeyStops`.
    public func operatorStops(for trip: Trip) async throws -> [String: [String]] {
        guard let first = trip.stopovers.first(where: { $0.departure != nil }), let departure = first.departure,
              let course = try await journeyCourse(line: trip.line, station: first.station, plannedDeparture: departure.planned)
        else { return [:] }
        return Self.operatorStops(course.operators, stops: course.stops, stopovers: trip.stopovers)
    }

    /// Each operator at the first stop of its section, and at the last one too unless it runs to the end,
    /// placed on `stopovers` (the app's own stop list) by planned time and place.
    static func operatorStops(_ operators: [TrainOperator], stops: [JourneyStop], stopovers: [Stopover]) -> [String: [String]] {
        guard operators.count > 1 else { return [:] }
        var marks: [String: [String]] = [:]
        func mark(_ name: String, at stop: JourneyStop) {
            guard let stopover = stopovers.first(where: { stopover in
                guard isNear(stop, stopover.station) else { return false }
                let times = [(stop.departure, stopover.departure), (stop.arrival, stopover.arrival)]
                return times.contains { pair in
                    guard let a = pair.0?.planned, let b = pair.1?.planned else { return false }
                    return abs(a.timeIntervalSince(b)) < 60
                }
            }) else { return }
            if marks[stopover.id, default: []].last != name { marks[stopover.id, default: []].append(name) }
        }
        for (index, entry) in operators.enumerated() {
            guard let section = entry.section,
                  let from = stops.firstIndex(where: { Station.normalize($0.name) == Station.normalize(section.from) }),
                  let to = stops.indices.last(where: { $0 >= from && Station.normalize(stops[$0].name) == Station.normalize(section.to) })
            else { continue }
            mark(entry.name, at: stops[from])
            if index < operators.count - 1 { mark(entry.name, at: stops[to]) }
        }
        return marks
    }

    private func journeyCourse(line: Line?, station: Station, plannedDeparture: Date,
                               maxAge: TimeInterval = BahnDeClient.journeyStopsMaxAge) async throws -> JourneyCourse? {
        guard let ref = Self.journeyReference(for: line), let line else { return nil }
        let journeyKey = "\(ref.category) \(ref.number)|\(station.id)|\(plannedDeparture.timeIntervalSince1970)"
        guard usesSharedCaches else {
            let id = try await findJourneyId(line: line, station: station, plannedDeparture: plannedDeparture)
            return try await fetchJourneyCourse(journeyId: id, feedOperator: line.operatorName)
        }
        // The journey ID of a run never changes, so resolving it (a departure board request) only
        // happens once; the stops themselves are refreshed every few minutes.
        let id = try await Self.journeyIdCache.value(for: journeyKey, maxAge: 12 * 3600) {
            try await self.findJourneyId(line: line, station: station, plannedDeparture: plannedDeparture)
        }
        return try await Self.journeyCourseCache.value(for: id, maxAge: maxAge) {
            try await self.fetchJourneyCourse(journeyId: id, feedOperator: line.operatorName)
        }
    }

    private static let journeyIdCache = ExpiringCache<String>()
    private static let journeyCourseCache = ExpiringCache<JourneyCourse>()
    /// Matches `TimetablesClient.changesMaxAge`: short enough that a realtime refresh still sees
    /// changes soon, long enough that reopening the same view right after doesn't wait again.
    public static let journeyStopsMaxAge: TimeInterval = 4 * 60

    /// The train to look up bahn.de's journey details for: long-distance trains by their number, and
    /// regional trains (RE 3 running as 3307) by their run number, since a Zusatzhalt happens there
    /// just as well, e.g. an RE 3 diverted via Berlin-Lichtenberg.
    static func journeyReference(for line: Line?) -> (category: String, number: String, isRegional: Bool)? {
        if let ref = trainReference(for: line) { return (ref.category, ref.number, false) }
        guard let ref = regionalReference(for: line, products: [.regionalExpress, .regional]) else { return nil }
        return (ref.category, ref.number, true)
    }

    /// bahn.de's journey ID for `line`, found on the departure board of `station` at its scheduled time.
    func findJourneyId(line: Line, station: Station, plannedDeparture: Date) async throws -> String {
        guard let eva = try await evaNumber(for: station) else { throw TransitError.notFound(line.name) }
        let regional = Self.journeyReference(for: line)?.isRegional == true
        let board = try await get(Self.boardURL(eva: eva, at: plannedDeparture, products: regional ? Self.regionalProducts : Self.longDistanceProducts),
                                  as: Board.self)
        guard let id = Self.journeyId(in: board, for: line, plannedDeparture: plannedDeparture) else {
            throw TransitError.notFound(line.name)
        }
        reportSightings(board.entries.filter { $0.journeyId == id })
        return id
    }

    /// bahn.de's product filters for its boards: long-distance trains, or regional ones (its
    /// "IR" and "REGIONAL" products, as in db-vendo-client); no filter at all for `[]`.
    static let longDistanceProducts = ["ICE", "EC_IC"]
    static let regionalProducts = ["IR", "REGIONAL"]
    /// Local trains: matched against bahn.de's regional and S-Bahn entries (`isLocal`).
    static let localTrainProducts: Set<Product> = [.regionalExpress, .regional, .suburban]

    static func boardURL(eva: String, at date: Date, kind: BoardKind = .departures, products: [String] = longDistanceProducts) -> URL {
        // Starting a minute early so the train itself is on the board even at a full minute.
        let start = date.addingTimeInterval(-60)
        let path = kind == .departures ? "reiseloesung/abfahrten" : "reiseloesung/ankuenfte"
        return baseURL.appending(path: path).appending(queryItems: [
            .init(name: "datum", value: berlinDay(start)),
            .init(name: "zeit", value: berlinTime(start)),
            .init(name: "ortExtId", value: eva),
            .init(name: "ortId", value: "A=1@L=\(eva)@"),
            .init(name: "mitVias", value: "false"),
        ] + products.map { .init(name: "verkehrsmittel[]", value: $0) })
    }

    /// The board entry running as `line` closest to its scheduled departure (within 30 minutes).
    /// Matched by name, or by train number alone, since bahn.de can brand a train differently than
    /// Transitous does (e.g. "RJ 171" for Transitous' "ICE 171"). Where the journey ID carries the
    /// train's number, that decides: a regional line's name ("RE 3") is shared by every run in both
    /// directions.
    static func journeyId(in board: Board, for line: Line, plannedDeparture: Date) -> String? {
        let targets = Set([line.name, line.alternateName].compactMap { $0 }.map(normalizedTrainName))
        let number = journeyReference(for: line)?.number
        return board.entries
            .filter { entry in
                if let number, let run = journeyNumber(in: entry.journeyId) { return run == number }
                let names = [entry.verkehrmittel?.name, entry.verkehrmittel?.mittelText].compactMap { $0 }
                return names.contains { targets.contains(normalizedTrainName($0)) }
                    || (number != nil && names.contains { trainNumber(in: $0) == number })
            }
            .compactMap { entry in entry.zeit.flatMap(parseBerlinTime).map { (entry.journeyId, abs($0.timeIntervalSince(plannedDeparture))) } }
            .filter { $0.1 <= 30 * 60 }
            .min { $0.1 < $1.1 }?.0
    }

    /// The train number in a bahn.de journey ID ("…#ZE#3307#ZB#RE 3…" → "3307"), nil without one.
    static func journeyNumber(in journeyId: String) -> String? {
        guard let start = journeyId.range(of: "#ZE#") else { return nil }
        let value = journeyId[start.upperBound...].prefix { $0 != "#" }
        return trainNumber(in: String(value))
    }

    /// "ICE 693" / "ICE693" → "ICE693".
    static func normalizedTrainName(_ name: String) -> String {
        name.filter { !$0.isWhitespace }.uppercased()
    }

    /// "RJ 171" → "171"; nil without a trailing number.
    static func trainNumber(in name: String) -> String? {
        let digits = String(name.reversed().prefix { $0.isNumber }.reversed())
        let trimmed = String(digits.drop { $0 == "0" })
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Train names

    /// `entries` (a departure or arrival board) with every DB long-distance train renamed to what
    /// bahn.de's own board of the same kind calls it, and with DB's live time from there for every
    /// train, RE/RB and S-Bahn included (`applyingLiveTimes`). For some cross-border trains Transitous only has DB's GTFS entry,
    /// which brands them generically, e.g. the ČD Railjet "RJ 171" Hamburg–Dresden as "ICE 171".
    /// Unchanged if bahn.de can't be asked (blocked, offline).
    public func correctingFromBoard(_ entries: [BoardEntry], at station: Station) async -> [BoardEntry] {
        // A board is all departures or all arrivals; bahn.de's matching board has the same kind.
        guard let kind = entries.first?.kind else { return entries }
        let trains = entries.filter { $0.kind == kind && Self.isLookedUp($0.line) }
        let times = trains.map(\.time.planned)
        guard let first = times.min(), let last = times.max(), let eva = try? await evaNumber(for: station) else { return entries }
        // Regional and S-Bahn rows only when the board has some, so a long-distance-only board stays small.
        let products = trains.contains { Self.trainReference(for: $0.line) == nil }
            ? Self.longDistanceProducts + Self.regionalProducts + ["SBAHN"] : Self.longDistanceProducts
        // One bahn.de board covers about an hour; the app's boards are 90 minutes.
        var board: [Board.Entry] = []
        var start = first
        for _ in 0..<3 {
            guard let page = try? await get(Self.boardURL(eva: eva, at: start, kind: kind, products: products), as: Board.self) else { break }
            board += page.entries
            guard let latest = page.entries.compactMap({ $0.zeit.flatMap(Self.parseBerlinTime) }).max(), latest < last else { break }
            start = latest.addingTimeInterval(60)
        }
        reportSightings(trains.compactMap { Self.boardMatch(for: $0, in: board) })
        return Self.applyingLiveTimes(Self.correctingTrainNames(entries, using: board, kind: kind), using: board, kind: kind)
    }

    /// Renames each entry of `kind` whose train number bahn.de's board of the same kind lists at the
    /// same scheduled time (±2 min) under another name. The Transitous name stays available as
    /// `alternateName`.
    static func correctingTrainNames(_ entries: [BoardEntry], using board: [Board.Entry], kind: BoardKind = .departures) -> [BoardEntry] {
        entries.map { entry in
            guard entry.kind == kind,
                  let name = bahnDeName(for: entry.line, plannedDeparture: entry.time.planned, in: board) else { return entry }
            var corrected = entry
            corrected.line = renamed(entry.line, to: name)
            return corrected
        }
    }

    /// bahn.de's name for `line` departing (or, on an arrivals board, arriving) at `plannedDeparture`
    /// (±2 min) on `board`, if it differs.
    static func bahnDeName(for line: Line?, plannedDeparture: Date, in board: [Board.Entry]) -> String? {
        guard let line, let match = boardEntry(for: line, plannedDeparture: plannedDeparture, in: board),
              let name = match.verkehrmittel?.name,
              normalizedTrainName(name) != normalizedTrainName(line.name) else { return nil }
        return name
    }

    /// The long-distance entry on `board` with `line`'s train number at `plannedDeparture` (±2 min).
    static func boardEntry(for line: Line?, plannedDeparture: Date, in board: [Board.Entry]) -> Board.Entry? {
        guard let number = trainReference(for: line)?.number else { return nil }
        return board.first { candidate in
            guard !isLocal(candidate), let name = candidate.verkehrmittel?.name, trainNumber(in: name) == number,
                  let time = candidate.zeit.flatMap(parseBerlinTime) else { return false }
            return abs(time.timeIntervalSince(plannedDeparture)) <= 120
        }
    }

    /// Whether `applyingLiveTimes` looks `line` up on bahn.de's board: every train, no subway, tram or bus.
    static func isLookedUp(_ line: Line) -> Bool {
        line.product.isTrain
    }

    /// bahn.de's entry for a train `boardEntry` can't look up by its number: regional and S-Bahn
    /// trains, and long-distance ones of other brands (NJ, FLX, TGV). By its run number (RE 4 as
    /// 3148, S5 as 5540), which the journey ID carries, at the same planned time (±1 min). A line's
    /// name alone ("S5") is shared by every run, so without a run number on both sides the name must
    /// match at that minute, and only one entry may.
    static func otherBoardEntry(for line: Line, plannedDeparture: Date, in board: [Board.Entry]) -> Board.Entry? {
        let local = localTrainProducts.contains(line.product)
        let matches = board.filter { candidate in
            guard isLocal(candidate) == local, let time = candidate.zeit.flatMap(parseBerlinTime),
                  abs(time.timeIntervalSince(plannedDeparture)) <= 60 else { return false }
            if let run = line.tripNumber, let theirs = journeyNumber(in: candidate.journeyId) { return run == theirs }
            let names = [candidate.verkehrmittel?.name, candidate.verkehrmittel?.mittelText].compactMap { $0 }
            return names.contains { normalizedTrainName($0) == normalizedTrainName(line.name) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A regional or S-Bahn entry of bahn.de's board; entries without a `produktGattung` count as
    /// long-distance, as on the long-distance-only board.
    static func isLocal(_ entry: Board.Entry) -> Bool {
        ["REGIONAL", "SBAHN"].contains(entry.verkehrmittel?.produktGattung ?? "")
    }

    /// Each train of `kind` (long-distance, RE/RB, S-Bahn; no subway, tram or bus) with DB's live time from bahn.de's board
    /// of the same kind, where it has one. Transitous' realtime for DB trains is DELFI's forecast,
    /// which can differ from DB's own: ICE 146 at Berlin Hbf left at 9:08 there, a minute before its
    /// planned time, while DB had it on time. Entries bahn.de has no live time for keep Transitous'.
    static func applyingLiveTimes(_ entries: [BoardEntry], using board: [Board.Entry], kind: BoardKind = .departures) -> [BoardEntry] {
        entries.map { entry in
            guard entry.kind == kind, let live = boardMatch(for: entry, in: board)?.ezZeit.flatMap(parseBerlinTime) else { return entry }
            var corrected = entry
            corrected.time.actual = live
            return corrected
        }
    }

    /// bahn.de's board entry for `entry`'s train: long-distance trains by number, other trains by run
    /// number or name (`otherBoardEntry`); nil for subway, tram and bus.
    static func boardMatch(for entry: BoardEntry, in board: [Board.Entry]) -> Board.Entry? {
        trainReference(for: entry.line) != nil
            ? boardEntry(for: entry.line, plannedDeparture: entry.time.planned, in: board)
            : isLookedUp(entry.line)
                ? otherBoardEntry(for: entry.line, plannedDeparture: entry.time.planned, in: board) : nil
    }

    /// `entries` whose line is still unknown ("?", see `TransitousProvider.namingUnknownLines`) named
    /// after bahn.de's board of the same kind: the train there at the same scheduled time (±1 min) to
    /// the same destination. One board request, only when such an entry is there.
    public func namingUnknownLines(_ entries: [BoardEntry], at station: Station) async -> [BoardEntry] {
        let unknown = entries.filter { TransitousProvider.isUnknown($0.line) }
        guard let first = unknown.map(\.time.planned).min(), let kind = unknown.first?.kind,
              let eva = try? await evaNumber(for: station),
              let board = try? await get(Self.boardURL(eva: eva, at: first, kind: kind, products: []), as: Board.self)
        else { return entries }
        return Self.namingUnknownLines(entries, using: board.entries)
    }

    static func namingUnknownLines(_ entries: [BoardEntry], using board: [Board.Entry]) -> [BoardEntry] {
        entries.map { entry in
            guard TransitousProvider.isUnknown(entry.line) else { return entry }
            let matches = board.filter { candidate in
                guard let time = candidate.zeit.flatMap(parseBerlinTime),
                      abs(time.timeIntervalSince(entry.time.planned)) <= 60,
                      candidate.verkehrmittel?.name?.isEmpty == false else { return false }
                guard let terminus = candidate.terminus, let otherEnd = entry.otherEnd else { return true }
                let a = Station.normalize(Station.displayName(for: terminus))
                let b = Station.normalize(otherEnd)
                return a.contains(b) || b.contains(a)
            }
            guard matches.count == 1, let transport = matches[0].verkehrmittel, let name = transport.name else { return entry }
            let product = product(forGattung: transport.produktGattung)
            var named = entry
            // "S 1" → "S1", like the other S- and U-Bahn rows.
            let compact = [.suburban, .subway].contains(product) ? name.replacingOccurrences(of: " ", with: "") : name
            named.line = Line(name: compact, number: trainNumber(in: name), product: product, operatorName: entry.line.operatorName)
            return named
        }
    }

    /// bahn.de's `produktGattung` ("SBAHN", "REGIONAL", …) as a `Product`.
    static func product(forGattung gattung: String?) -> Product {
        switch gattung {
        case "ICE": .highSpeed
        case "EC_IC", "IR": .longDistance
        case "REGIONAL": .regional
        case "SBAHN": .suburban
        case "UBAHN": .subway
        case "TRAM": .tram
        case "BUS", "ANRUFPFLICHTIG": .bus
        case "SCHIFF": .ferry
        default: .other
        }
    }

    static func renamed(_ line: Line, to name: String) -> Line {
        var line = line
        line.alternateName = line.alternateName ?? line.name
        line.name = name
        return line
    }

    /// `journeys` with every DB long-distance leg renamed to what bahn.de's departure board at the
    /// leg's origin calls the train (see `correctingFromBoard(_:at:)`). One board request per
    /// distinct train and origin, cached for the day; unchanged legs if bahn.de can't be asked.
    public func correctingTrainNames(in journeys: [Journey]) async -> [Journey] {
        struct Key: Hashable { let station: Station; let planned: Date; let line: Line }
        var keys = Set<Key>()
        for leg in journeys.flatMap(\.legs) where !leg.isWalking && !leg.cancelled {
            if let line = leg.line, Self.trainReference(for: line) != nil {
                keys.insert(Key(station: leg.origin, planned: leg.departure.planned, line: line))
            }
        }
        guard !keys.isEmpty else { return journeys }
        var names: [Key: String] = [:]
        await withTaskGroup(of: (Key, String?).self) { group in
            for key in keys {
                group.addTask { (key, await self.bahnDeName(for: key.line, at: key.station, plannedDeparture: key.planned)) }
            }
            for await (key, name) in group { if let name { names[key] = name } }
        }
        guard !names.isEmpty else { return journeys }
        return journeys.map { journey in
            var journey = journey
            journey.legs = journey.legs.map { leg in
                guard let line = leg.line, let name = names[Key(station: leg.origin, planned: leg.departure.planned, line: line)] else { return leg }
                var leg = leg
                leg.line = Self.renamed(line, to: name)
                return leg
            }
            return journey
        }
    }

    private func bahnDeName(for line: Line, at station: Station, plannedDeparture: Date) async -> String? {
        let fetch: @Sendable () async throws -> String? = {
            guard let eva = try await self.evaNumber(for: station) else { return nil }
            let board = try await self.get(Self.boardURL(eva: eva, at: plannedDeparture), as: Board.self)
            self.reportSightings([Self.boardEntry(for: line, plannedDeparture: plannedDeparture, in: board.entries)].compactMap { $0 })
            // "" for "same name" so that answer is cached too.
            return Self.bahnDeName(for: line, plannedDeparture: plannedDeparture, in: board.entries) ?? ""
        }
        let key = "\(line.name)|\(station.id)|\(plannedDeparture.timeIntervalSince1970)"
        let name = usesSharedCaches
            ? try? await Self.trainNameCache.value(for: key, maxAge: 12 * 3600, fetch: fetch)
            : try? await fetch()
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    private static let trainNameCache = ExpiringCache<String?>()

    private func fetchJourneyCourse(journeyId: String, feedOperator: String?) async throws -> JourneyCourse {
        let details = try await get(Self.journeyURL(journeyId), as: JourneyDetails.self)
        return JourneyCourse(stops: details.halte.compactMap(JourneyStop.init),
                             operators: Self.operators(of: details, feedOperator: feedOperator),
                             hasSleepingCars: details.hasSleepingCars)
    }

    /// The operators bahn.de names in the train's attributes, unless its stops' railways (`adminID`, else
    /// their country) name more: then the attributes only list some of them, and the Railjet København →
    /// Praha, run by DSB, DB and ČD, showed as DSB's alone. The stops' version also wins when it names as
    /// many and the attributes have no sections, since it knows where each railway takes over.
    ///
    /// The stations' countries only stand for national railways, so they are only asked when the feed
    /// names one (`feedOperator`, or none at all): Die Länderbahn's trilex to Liberec or RegioJet to
    /// Bratislava would otherwise show DB Regio and ČD, ČD and ZSSK. Then the feed's operator stays.
    static func operators(of details: JourneyDetails, feedOperator: String? = nil) -> [TrainOperator] {
        let named = operators(in: details.zugattribute ?? [])
        let byCountry = !details.halte.contains { $0.adminID != nil }
        let countriesFit = feedOperator.map { OperatorBrand(operatorName: $0)?.isNationalRailway == true } ?? true
        let byAdministration = byCountry && !countriesFit ? [] : operators(byAdministration: details.halte, trainName: details.zugName)
        let namedCount = Set(named.map(\.name)).count, stopsCount = Set(byAdministration.map(\.name)).count
        // As many but without sections (one comma-separated attribute): the stops' version knows where each runs.
        if stopsCount > namedCount || (stopsCount > 0 && stopsCount == namedCount && !named.contains { $0.section != nil }) {
            return byAdministration
        }
        return named
    }

    /// The operators of a train run by several railways, from its stops' `adminID`s: one per run of
    /// stops with the same code, its section from the first to the last of them. Empty when the whole
    /// train has one code (the feed's operator names it better, e.g. "DB Regio AG NRW") or a code isn't
    /// known, so a railway is never silently left out.
    ///
    /// Without any `adminID` (RJ 383 København → Praha, 2026-10-07) each stop's country stands in for
    /// it: the UIC code its station number starts with ("8601309" København H: 86, DSB). A single stop
    /// abroad doesn't count (an ICE ending at Basel SBB is still DB's), only a run of two or more.
    /// `trainName` ("RJ 383") gives the category for stops without their own.
    static func operators(byAdministration stops: [JourneyDetails.Stop], trainName: String? = nil) -> [TrainOperator] {
        let byCountry = !stops.contains { $0.adminID != nil }
        var runs: [(admin: String, first: JourneyDetails.Stop, last: JourneyDetails.Stop, count: Int)] = []
        func add(_ admin: String, _ first: JourneyDetails.Stop, _ last: JourneyDetails.Stop, _ count: Int) {
            if let previous = runs.last, previous.admin == admin {
                runs[runs.count - 1].last = last
                runs[runs.count - 1].count += count
            } else {
                runs.append((admin, first, last, count))
            }
        }
        for stop in stops {
            guard let admin = byCountry ? countryCode(of: stop) : stop.adminID.map({ String($0.prefix(2)) }), admin.count == 2
            else { continue }
            add(admin, stop, stop, 1)
        }
        if byCountry {
            let all = runs
            runs = []
            for run in all where run.count > 1 { add(run.admin, run.first, run.last, run.count) }
        }
        guard Set(runs.map(\.admin)).count > 1 else { return [] }
        let trainCategory = trainName?.split(separator: " ").first.map(String.init)
        var operators: [TrainOperator] = []
        for run in runs {
            let category = (run.first.kategorie ?? trainCategory)?.uppercased() ?? ""
            guard let name = railwayName(uicCode: run.admin, longDistance: !regionalTrainCategories.contains(category)) else { return [] }
            operators.append(TrainOperator(name: name, section: .init(from: run.first.name, to: run.last.name)))
        }
        return operators
    }

    /// The UIC country code a stop's station number starts with: "8601309" (København H) → "86".
    static func countryCode(of stop: JourneyDetails.Stop) -> String? {
        guard let number = stop.extId ?? stop.evaNumber, number.count == 7, number.allSatisfy(\.isNumber) else { return nil }
        return String(number.prefix(2))
    }

    /// Categories of regional trains, whose DB part is DB Regio rather than DB Fernverkehr.
    static let regionalTrainCategories: Set<String> = ["RE", "RB", "IRE", "S", "RS", "MEX", "REX", "R", "OS", "SP", "IR"]

    /// The passenger railway behind a UIC country code as bahn.de uses it for `adminID`. Named like
    /// the feeds name them, so `OperatorBrand` finds their logos.
    static func railwayName(uicCode: String, longDistance: Bool) -> String? {
        switch uicCode {
        case "80": longDistance ? "DB Fernverkehr AG" : "DB Regio AG"
        case "81": "ÖBB Personenverkehr AG"
        case "85": "Schweizerische Bundesbahnen SBB"
        case "54": "České dráhy, a.s."
        case "51": longDistance ? "PKP Intercity" : "Polregio"
        case "56": "Železničná spoločnosť Slovensko, a.s."
        case "55": "MÁV-START"
        case "43": "GYSEV"
        case "84": "NS Reizigers"
        case "88": "SNCB"
        case "87": "SNCF"
        case "83": "Trenitalia"
        case "82": "CFL"
        case "86": "DSB"
        case "74": "SJ"
        case "79": "Slovenske železnice"
        case "78": "HŽ Putnički prijevoz"
        default: nil
        }
    }

    // MARK: Operators

    /// The "BEF" (or "OP") attributes as operators, in bahn.de's order and without repeats. A section
    /// hint like "(Berlin Hbf - Bad Schandau)" becomes the operator's section. One attribute can name
    /// several, comma-separated, as bahn.de's connections do: "Dänische Staatsbahnen, DB Fernverkehr AG,
    /// Ceske Drahy" (RJ 385, 2026-10-07).
    static func operators(in attributes: [JourneyDetails.Attribute]) -> [TrainOperator] {
        var operators: [TrainOperator] = []
        for attribute in attributes where attribute.key == "BEF" || attribute.key == "OP" {
            let section = attribute.teilstreckenHinweis.flatMap(section)
            for name in operatorNames(in: attribute.value ?? "") {
                let entry = TrainOperator(name: name, section: section)
                if !operators.contains(entry) { operators.append(entry) }
            }
        }
        return operators
    }

    /// "Dänische Staatsbahnen, DB Fernverkehr AG, Ceske Drahy" → its three names. A company's legal form
    /// after a comma stays with it: "České dráhy, a.s." is one name.
    static func operatorNames(in value: String) -> [String] {
        var names: [String] = []
        for part in value.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let isLegalForm = part.contains(".") && !part.contains(" ") && part.count <= 7
            if isLegalForm, let last = names.popLast() {
                names.append("\(last), \(part)")
            } else {
                names.append(part)
            }
        }
        return names
    }

    /// "(Berlin Hbf - Bad Schandau)" → Berlin Hbf … Bad Schandau. Only " - " with spaces separates,
    /// so hyphenated names like "Berlin-Spandau" stay whole.
    static func section(_ hint: String) -> TrainOperator.Section? {
        let trimmed = hint.trimmingCharacters(in: CharacterSet(charactersIn: "() ").union(.whitespaces))
        let parts = trimmed.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return TrainOperator.Section(from: parts[0], to: parts[1])
    }

    /// `operators` narrowed to those running some part of `leg`, located by bahn.de's own stop order:
    /// an operator whose section ends before the leg starts or starts after it ends is left out.
    /// Anything that can't be placed (no section, a station not found) is kept. Once only one operator
    /// is left, its section is dropped: it runs everything you ride.
    static func operators(_ operators: [TrainOperator], riding leg: Leg, stops: [JourneyStop]) -> [TrainOperator] {
        guard operators.count > 1,
              let legStart = stops.firstIndex(where: { stop in
                  stop.departure.map { abs($0.planned.timeIntervalSince(leg.departure.planned)) < 60 } == true && isNear(stop, leg.origin) }),
              let legEnd = stops.indices.last(where: { index in
                  index > legStart && stops[index].arrival.map { abs($0.planned.timeIntervalSince(leg.arrival.planned)) < 60 } == true
                      && isNear(stops[index], leg.destination) })
        else { return operators.count == 1 ? [TrainOperator(name: operators[0].name)] : operators }
        let riding = operators.filter { entry in
            guard let section = entry.section,
                  let from = stops.firstIndex(where: { Station.normalize($0.name) == Station.normalize(section.from) }),
                  let to = stops.indices.last(where: { $0 > from && Station.normalize(stops[$0].name) == Station.normalize(section.to) })
            else { return true }
            // Its section runs on to the next stop (Bad Schandau → Děčín is still DB's).
            return from < legEnd && to >= legStart
        }
        var seen = Set<String>()
        let unique = riding.filter { seen.insert($0.name).inserted }
        return unique.count == 1 ? [TrainOperator(name: unique[0].name)] : riding
    }

    /// Same place test as `stop(in:at:planned:side:)`, without the time.
    private static func isNear(_ stop: JourneyStop, _ station: Station) -> Bool {
        if matches(stop, station) || Station.normalize(stop.name) == Station.normalize(station.displayName) { return true }
        guard let a = stop.coordinate, let b = station.coordinate else { return false }
        return a.distance(to: b) < 1_000
    }

    static func journeyURL(_ journeyId: String) -> URL {
        // Journey IDs contain "#", which must reach bahn.de as "%23" rather than start a fragment.
        var components = URLComponents(url: baseURL.appending(path: "reiseloesung/fahrt"), resolvingAgainstBaseURL: false)!
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "#&=+")
        let id = journeyId.addingPercentEncoding(withAllowedCharacters: allowed) ?? journeyId
        components.percentEncodedQuery = "journeyId=\(id)&poly=false"
        return components.url!
    }

    // MARK: Platforms

    /// `leg` with every platform it lacks – at its start, its end and its stops – taken from bahn.de's
    /// journey details. DB's feed in Transitous has none at all at some stations (e.g. Hamburg Hbf and
    /// Hamburg-Altona) and DB Timetables only knows the next hours, while bahn.de has them days ahead.
    /// A stop is matched by its planned time and place, so a station passed twice can't mix them up.
    public static func fillingMissingPlatforms(in leg: Leg, from stops: [JourneyStop]) -> Leg {
        var leg = leg
        if leg.departurePlatform?.best == nil,
           let stop = stop(in: stops, at: leg.origin, planned: leg.departure.planned, side: \.departure) {
            leg.departurePlatform = stop.departurePlatform
        }
        if leg.arrivalPlatform?.best == nil,
           let stop = stop(in: stops, at: leg.destination, planned: leg.arrival.planned, side: \.arrival) {
            leg.arrivalPlatform = stop.arrivalPlatform
        }
        for index in leg.stopovers.indices {
            let stopover = leg.stopovers[index]
            if stopover.arrivalPlatform?.best == nil, let planned = stopover.arrival?.planned,
               let stop = stop(in: stops, at: stopover.station, planned: planned, side: \.arrival) {
                leg.stopovers[index].arrivalPlatform = stop.arrivalPlatform
            }
            if stopover.departurePlatform?.best == nil, let planned = stopover.departure?.planned,
               let stop = stop(in: stops, at: stopover.station, planned: planned, side: \.departure) {
                leg.stopovers[index].departurePlatform = stop.departurePlatform
            }
        }
        return leg
    }

    /// `leg` with DB's live times from bahn.de's journey details wherever bahn.de has one (`echtzeit`),
    /// at its start, its end and its stops. Transitous' realtime for cross-border trains often carries
    /// no delay at all and DB Timetables can miss a stop, so RJ 383 showed +59 at Dresden Hbf but none
    /// at Bad Schandau, where bahn.de had +57. Matched like the platforms, by planned time and place.
    public static func applyingLiveTimes(from stops: [JourneyStop], to leg: Leg) -> Leg {
        var leg = leg
        if let actual = stop(in: stops, at: leg.origin, planned: leg.departure.planned, side: \.departure)?.departure?.actual {
            leg.departure.actual = actual
        }
        if let actual = stop(in: stops, at: leg.destination, planned: leg.arrival.planned, side: \.arrival)?.arrival?.actual {
            leg.arrival.actual = actual
        }
        leg.stopovers = applyingLiveTimes(from: stops, to: leg.stopovers)
        return leg
    }

    /// `stopovers` with bahn.de's live times where it has one (see `applyingLiveTimes(from:to:)` for a leg).
    public static func applyingLiveTimes(from stops: [JourneyStop], to stopovers: [Stopover]) -> [Stopover] {
        var stopovers = stopovers
        for index in stopovers.indices {
            let stopover = stopovers[index]
            if let planned = stopover.arrival?.planned,
               let actual = stop(in: stops, at: stopover.station, planned: planned, side: \.arrival)?.arrival?.actual {
                stopovers[index].arrival?.actual = actual
            }
            if let planned = stopover.departure?.planned,
               let actual = stop(in: stops, at: stopover.station, planned: planned, side: \.departure)?.departure?.actual {
                stopovers[index].departure?.actual = actual
            }
        }
        return stopovers
    }

    /// Whether `leg` lacks a platform at its start, its end or any of its stops.
    public static func lacksPlatforms(_ leg: Leg) -> Bool {
        leg.departurePlatform?.best == nil || leg.arrivalPlatform?.best == nil
            || leg.stopovers.contains { ($0.arrival != nil && $0.arrivalPlatform?.best == nil)
                || ($0.departure != nil && $0.departurePlatform?.best == nil) }
    }

    /// The stop of `stops` at `station` whose `side` is planned at `planned`. Transitous and bahn.de
    /// name stations differently ("S Spandau Bhf (Berlin)" / "Berlin-Spandau"), so being within 1 km
    /// counts as the same place too – at the very same planned time that can only be this stop.
    private static func stop(in stops: [JourneyStop], at station: Station, planned: Date,
                             side: KeyPath<JourneyStop, TimeInfo?>) -> JourneyStop? {
        stops.first { stop in
            guard let time = stop[keyPath: side], abs(time.planned.timeIntervalSince(planned)) < 60 else { return false }
            if matches(stop, station) || Station.normalize(stop.name) == Station.normalize(station.displayName) { return true }
            guard let a = stop.coordinate, let b = station.coordinate else { return false }
            return a.distance(to: b) < 1_000
        }
    }

    // MARK: Zusatzhalt merging

    /// If `station` is a Zusatzhalt in `stops`, the pair of (that stop, the next stop after it that
    /// *is* part of the train's regular schedule) — the hop a Träwelling checkin needs to bridge with
    /// a manual trip before it can check in normally again. `nil` when `station` isn't a Zusatzhalt
    /// here, or there's no regular stop left after it (e.g. it's also the train's actual last stop).
    public static func nextRegularStop(after station: Station, in stops: [JourneyStop]) -> (zusatzhalt: JourneyStop, nextRegular: JourneyStop)? {
        guard let index = stops.firstIndex(where: { $0.isAdditional && matches($0, station) }) else { return nil }
        guard let next = stops[(index + 1)...].first(where: { !$0.isAdditional && !$0.isCancelled }) else { return nil }
        return (stops[index], next)
    }

    private static func matches(_ stop: JourneyStop, _ station: Station) -> Bool {
        if let eva = station.evaNumber, eva == stop.evaNumber { return true }
        return Station.normalize(stop.name) == Station.normalize(station.name)
    }

    /// Looser than `matches`, for anchoring bahn.de's stops in Transitous' list: regional trains carry
    /// local names there ("S Bernau Bhf" for bahn.de's "Bernau(b Berlin)") and no EVA number, so
    /// the display name or being within 400 m (as `Station.isSamePlace`) count too.
    private static func isSamePlace(_ stop: JourneyStop, _ station: Station) -> Bool {
        if matches(stop, station) || Station.normalize(stop.name) == Station.normalize(station.displayName) { return true }
        guard let a = stop.coordinate, let b = station.coordinate else { return false }
        return a.distance(to: b) < 400
    }

    /// `stopovers` (a leg's or trip's own schedule-only stop list) with every Zusatzhalt from `stops`
    /// inserted at its rightful place, so an unscheduled stop shows up in the UI instead of silently
    /// being missing — found by walking `stops` in bahn.de's own order and using every stop that
    /// *isn't* additional to re-anchor the position in `stopovers`, which already carries whatever
    /// realtime overlay (delay, cancellation) a caller applied. `stopovers` is returned unchanged if
    /// it's empty (stopovers were never loaded for this leg/trip) or `stops` has no Zusatzhalt at all.
    public static func inserting(_ stops: [JourneyStop], into stopovers: [Stopover]) -> [Stopover] {
        // Callers re-run this on every realtime refresh against a stop list that may already carry a
        // Zusatzhalt this same function spliced in last time — drop it first so it isn't duplicated.
        let stopovers = stopovers.filter { !$0.isAdditional }
        guard !stopovers.isEmpty, stops.contains(where: \.isAdditional) else { return stopovers }
        var result: [Stopover] = []
        var index = 0
        for stop in stops {
            if stop.isAdditional {
                result.append(Stopover(stop))
                continue
            }
            guard let match = stopovers[index...].firstIndex(where: { isSamePlace(stop, $0.station) }) else { continue }
            result.append(contentsOf: stopovers[index..<match])
            result.append(stopovers[match])
            index = match + 1
        }
        result.append(contentsOf: stopovers[index...])
        return result
    }

    // MARK: Berlin local time

    /// `HH:mm:00` in Europe/Berlin, as the departure board wants it.
    static func berlinTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d:00", parts.hour!, parts.minute!)
    }

    /// bahn.de's zone-less local timestamps, e.g. "2026-09-29T22:38:00".
    static func parseBerlinTime(_ string: String) -> Date? {
        if let date = JSONDecoding.parseISODate(string) { return date }
        let parts = string.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: parts[3], minute: parts[4], second: parts.count > 5 ? parts[5] : 0))
    }
}

extension JourneyStop {
    /// Same rules as Travel::Status::DE::DBRIS' `Location`: the flags, or a "Zusatzhalt" /
    /// `HALT_AUSFALL` message, or the RIS key for a cancelled stop.
    init?(_ stop: BahnDeClient.JourneyDetails.Stop) {
        let idParts = BahnDeClient.hafasFields(stop.id)
        guard let eva = stop.extId ?? stop.evaNumber ?? idParts["L"] else { return nil }
        let messages = stop.priorisierteMeldungen ?? []
        let time = { (planned: String?, actual: String?) -> TimeInfo? in
            guard let planned = planned.flatMap(BahnDeClient.parseBerlinTime) else { return nil }
            return TimeInfo(planned: planned, actual: actual.flatMap(BahnDeClient.parseBerlinTime))
        }
        let platform = stop.gleis != nil || stop.ezGleis != nil ? PlatformInfo(planned: stop.gleis, actual: stop.ezGleis) : nil
        var coordinate: Coordinate?
        if let x = idParts["X"].flatMap(Double.init), let y = idParts["Y"].flatMap(Double.init) {
            coordinate = Coordinate(latitude: y / 1e6, longitude: x / 1e6)
        }
        self.init(evaNumber: eva, name: stop.name, coordinate: coordinate,
                  arrival: time(stop.ankunft?.sollzeit ?? stop.ankunftsZeitpunkt, stop.ankunft?.echtzeit ?? stop.ezAnkunftsZeitpunkt),
                  departure: time(stop.abfahrt?.sollzeit ?? stop.abfahrtsZeitpunkt, stop.abfahrt?.echtzeit ?? stop.ezAbfahrtsZeitpunkt),
                  arrivalPlatform: platform, departurePlatform: platform,
                  isAdditional: stop.additional == true || messages.contains { $0.text == "Zusatzhalt" },
                  isCancelled: stop.canceled == true || messages.contains { $0.type == "HALT_AUSFALL" }
                      || (stop.risMeldungen ?? []).contains { $0.key == "text.realtime.stop.cancelled" })
    }
}

extension BahnDeClient {
    /// "A=1@O=Frankfurt(Main)Hbf@X=8663785@Y=50107149@L=8000105@" → ["A": "1", "O": …, "L": "8000105"].
    static func hafasFields(_ id: String?) -> [String: String] {
        var fields: [String: String] = [:]
        for part in (id ?? "").split(separator: "@") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }
}
