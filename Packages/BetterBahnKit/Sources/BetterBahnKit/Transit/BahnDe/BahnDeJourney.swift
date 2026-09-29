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
    /// on delays/platforms) since it only ever has the planned schedule. `nil` if `leg`'s train isn't a
    /// DB long-distance category; throws `TransitError.notFound` if bahn.de doesn't list it.
    public func journeyStops(for leg: Leg) async throws -> [JourneyStop]? {
        try await journeyStops(line: leg.line, station: leg.origin, plannedDeparture: leg.departure.planned)
    }

    /// The realtime stop sequence for `trip`'s train (see `journeyStops(for:)` above); `nil` under the
    /// same conditions, plus when `trip` has no departing stop to look the train up at.
    public func journeyStops(for trip: Trip) async throws -> [JourneyStop]? {
        guard let first = trip.stopovers.first(where: { $0.departure != nil }), let departure = first.departure else { return nil }
        return try await journeyStops(line: trip.line, station: first.station, plannedDeparture: departure.planned)
    }

    private func journeyStops(line: Line?, station: Station, plannedDeparture: Date) async throws -> [JourneyStop]? {
        guard let ref = Self.trainReference(for: line), let line else { return nil }
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
        return try await Self.journeyStopsCache.value(for: id, maxAge: Self.journeyStopsMaxAge) {
            try await self.fetchJourneyStops(journeyId: id)
        }
    }

    private static let journeyIdCache = ExpiringCache<String>()
    private static let journeyStopsCache = ExpiringCache<[JourneyStop]>()
    /// Matches `TimetablesClient.changesMaxAge`: short enough that a realtime refresh still sees
    /// changes soon, long enough that reopening the same view right after doesn't wait again.
    static let journeyStopsMaxAge: TimeInterval = 4 * 60

    /// bahn.de's journey ID for `line`, found on the departure board of `station` at its scheduled time.
    func findJourneyId(line: Line, station: Station, plannedDeparture: Date) async throws -> String {
        guard let eva = try await evaNumber(for: station) else { throw TransitError.notFound(line.name) }
        let board = try await get(Self.boardURL(eva: eva, at: plannedDeparture), as: Board.self)
        guard let id = Self.journeyId(in: board, for: line, plannedDeparture: plannedDeparture) else {
            throw TransitError.notFound(line.name)
        }
        return id
    }

    static func boardURL(eva: String, at date: Date) -> URL {
        // Starting a minute early so the train itself is on the board even at a full minute.
        let start = date.addingTimeInterval(-60)
        return baseURL.appending(path: "reiseloesung/abfahrten").appending(queryItems: [
            .init(name: "datum", value: berlinDay(start)),
            .init(name: "zeit", value: berlinTime(start)),
            .init(name: "ortExtId", value: eva),
            .init(name: "ortId", value: "A=1@L=\(eva)@"),
            .init(name: "mitVias", value: "false"),
            .init(name: "verkehrsmittel[]", value: "ICE"),
            .init(name: "verkehrsmittel[]", value: "EC_IC"),
        ])
    }

    /// The board entry running as `line` closest to its scheduled departure (within 30 minutes).
    static func journeyId(in board: Board, for line: Line, plannedDeparture: Date) -> String? {
        let target = normalizedTrainName(line.name)
        return board.entries
            .filter { entry in
                [entry.verkehrmittel?.name, entry.verkehrmittel?.mittelText].contains { $0.map(normalizedTrainName) == target }
            }
            .compactMap { entry in entry.zeit.flatMap(parseBerlinTime).map { (entry.journeyId, abs($0.timeIntervalSince(plannedDeparture))) } }
            .filter { $0.1 <= 30 * 60 }
            .min { $0.1 < $1.1 }?.0
    }

    /// "ICE 693" / "ICE693" → "ICE693".
    static func normalizedTrainName(_ name: String) -> String {
        name.filter { !$0.isWhitespace }.uppercased()
    }

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
            guard let match = stopovers[index...].firstIndex(where: { matches(stop, $0.station) }) else { continue }
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
