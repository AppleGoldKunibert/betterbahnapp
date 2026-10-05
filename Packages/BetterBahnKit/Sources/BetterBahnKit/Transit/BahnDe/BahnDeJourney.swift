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
            struct Transport: Decodable { var name: String?; var mittelText: String? }
            var journeyId: String
            /// Scheduled departure, Berlin local time without zone, e.g. "2026-09-29T22:38:00".
            var zeit: String?
            var verkehrmittel: Transport?
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
        }
        var halte: [Stop]
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
        guard let ref = Self.journeyReference(for: line), let line else { return nil }
        let journeyKey = "\(ref.category) \(ref.number)|\(station.id)|\(plannedDeparture.timeIntervalSince1970)"
        guard usesSharedCaches else {
            let id = try await findJourneyId(line: line, station: station, plannedDeparture: plannedDeparture)
            return try await fetchJourneyStops(journeyId: id)
        }
        // The journey ID of a run never changes, so resolving it (a departure board request) only
        // happens once; the stops themselves are refreshed every few minutes.
        let id = try await Self.journeyIdCache.value(for: journeyKey, maxAge: 12 * 3600) {
            try await self.findJourneyId(line: line, station: station, plannedDeparture: plannedDeparture)
        }
        return try await Self.journeyStopsCache.value(for: id, maxAge: maxAge) {
            try await self.fetchJourneyStops(journeyId: id)
        }
    }

    private static let journeyIdCache = ExpiringCache<String>()
    private static let journeyStopsCache = ExpiringCache<[JourneyStop]>()
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
        return id
    }

    /// bahn.de's product filters for its boards: long-distance trains, or regional ones (its
    /// "IR" and "REGIONAL" products, as in db-vendo-client).
    static let longDistanceProducts = ["ICE", "EC_IC"]
    static let regionalProducts = ["IR", "REGIONAL"]

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
    /// bahn.de's own board of the same kind calls it. For some cross-border trains Transitous only has DB's GTFS entry,
    /// which brands them generically, e.g. the ČD Railjet "RJ 171" Hamburg–Dresden as "ICE 171".
    /// Unchanged if bahn.de can't be asked (blocked, offline).
    public func correctingTrainNames(_ entries: [BoardEntry], at station: Station) async -> [BoardEntry] {
        // A board is all departures or all arrivals; bahn.de's matching board has the same kind.
        guard let kind = entries.first?.kind else { return entries }
        let times = entries.filter { $0.kind == kind && Self.trainReference(for: $0.line) != nil }.map(\.time.planned)
        guard let first = times.min(), let last = times.max(), let eva = try? await evaNumber(for: station) else { return entries }
        // One bahn.de board covers about an hour; the app's boards are 90 minutes.
        var board: [Board.Entry] = []
        var start = first
        for _ in 0..<3 {
            guard let page = try? await get(Self.boardURL(eva: eva, at: start, kind: kind), as: Board.self) else { break }
            board += page.entries
            guard let latest = page.entries.compactMap({ $0.zeit.flatMap(Self.parseBerlinTime) }).max(), latest < last else { break }
            start = latest.addingTimeInterval(60)
        }
        return Self.correctingTrainNames(entries, using: board, kind: kind)
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
        guard let line, let number = trainReference(for: line)?.number,
              let match = board.first(where: { candidate in
                  guard let name = candidate.verkehrmittel?.name, trainNumber(in: name) == number,
                        let time = candidate.zeit.flatMap(parseBerlinTime) else { return false }
                  return abs(time.timeIntervalSince(plannedDeparture)) <= 120
              }),
              let name = match.verkehrmittel?.name,
              normalizedTrainName(name) != normalizedTrainName(line.name) else { return nil }
        return name
    }

    static func renamed(_ line: Line, to name: String) -> Line {
        var line = line
        line.alternateName = line.alternateName ?? line.name
        line.name = name
        return line
    }

    /// `journeys` with every DB long-distance leg renamed to what bahn.de's departure board at the
    /// leg's origin calls the train (see `correctingTrainNames(_:at:)`). One board request per
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

    private func fetchJourneyStops(journeyId: String) async throws -> [JourneyStop] {
        try await get(Self.journeyURL(journeyId), as: JourneyDetails.self).halte.compactMap(JourneyStop.init)
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
