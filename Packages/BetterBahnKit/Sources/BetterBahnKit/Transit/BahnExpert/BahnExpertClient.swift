import Foundation

/// Result of a bahn.expert train-type lookup for one train on one calendar day.
public struct TrainTypeLookup: Codable, Sendable, Hashable {
    public enum FormationStatus: String, Codable, Sendable {
        /// The formation is the timetable's plan (`Planwagenreihung`), not a live assignment.
        case planned
        /// Live data from the operator. The actual vehicles may differ from the plan.
        case realtime
    }

    public struct Group: Codable, Sendable, Hashable {
        /// bahn.expert's series label, e.g. "ICE 4 Lang (BR412)".
        public var seriesName: String?
        /// Baureihe number, e.g. "412".
        public var baureihe: String?
        /// Triebzug number (only present for live data), e.g. "9465".
        public var unitNumber: String?
        public var origin: String?
        public var destination: String?
        public var coachCount: Int

        /// Marketing family: "ICE 1", "ICE 2", "ICE 3", "ICE 3neo", "ICE 4", "ICE T", "ICE L", or the
        /// cleaned-up bahn.expert name for anything else (e.g. "IC 2").
        public var family: String? {
            switch baureihe {
            case "401": "ICE 1"
            case "402": "ICE 2"
            case "403", "406", "407": "ICE 3"
            case "408": "ICE 3neo"
            case "411", "415": "ICE T"
            case "412": "ICE 4"
            default: seriesName.map(TrainTypeLookup.family(of:))
            }
        }
    }

    public var category: String
    public var number: String
    /// Calendar day (Europe/Berlin) as `yyyy-MM-dd`.
    public var date: String
    public var administration: String
    public var groups: [Group]
    public var status: FormationStatus
    /// Where the data came from, e.g. "DB-plan".
    public var source: String?
    public var retrievedAt: Date

    /// Public page the same data is shown on, so the user can verify or open it.
    public var pageURL: URL? { BahnExpertClient.pageURL(category: category, number: number, date: date, administration: administration) }

    /// Distinct marketing families in order, e.g. ["ICE 4"] — "ICE 4 Lang (BR412)" collapses to "ICE 4".
    public var families: [String] {
        var result: [String] = []
        for family in groups.compactMap(\.family) where !result.contains(family) {
            result.append(family)
        }
        return result
    }

    /// "ICE 4" or "ICE 3neo + ICE 4"; nil if bahn.expert knows no series.
    public var summary: String? { families.isEmpty ? nil : families.joined(separator: " + ") }

    /// Adapter for the existing formation UI.
    public var formation: TrainFormation {
        TrainFormation(units: groups.map { .init(model: $0.family, number: $0.unitNumber) })
    }

    /// Strips the variant and the parenthesised class: "ICE 4 Lang (BR412)" → "ICE 4", "ICE 3neo (BR408)" → "ICE 3neo".
    static func family(of seriesName: String) -> String {
        var name = seriesName
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        name = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" Lang", " Kurz"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        return name
    }
}

/// One stop of a journey's realtime course, as bahn.expert reports it (sourced from DB's RIS::Journeys
/// feed) — the only source in this app that carries a Zusatzhalt (an unscheduled stop a train
/// additionally picked up, e.g. after a diversion) or a stop it skipped, since Transitous and
/// Träwelling's own trip data only carry the planned schedule.
public struct JourneyStop: Sendable, Hashable {
    public var evaNumber: String
    public var name: String
    public var arrival: TimeInfo?
    public var departure: TimeInfo?
    public var arrivalPlatform: PlatformInfo?
    public var departurePlatform: PlatformInfo?
    public var isAdditional: Bool
    public var isCancelled: Bool

    init(_ stop: BahnExpertClient.Details.Stop) {
        evaNumber = stop.stopPlace.evaNumber
        name = stop.stopPlace.name ?? stop.stopPlace.evaNumber
        arrival = stop.arrival.map { TimeInfo(planned: $0.scheduledTime, actual: $0.time) }
        departure = stop.departure.map { TimeInfo(planned: $0.scheduledTime, actual: $0.time) }
        arrivalPlatform = Self.platform(stop.arrival)
        departurePlatform = Self.platform(stop.departure)
        isAdditional = stop.additional ?? false
        isCancelled = stop.cancelled ?? false
    }

    private static func platform(_ event: BahnExpertClient.Details.Stop.Event?) -> PlatformInfo? {
        guard let event, event.scheduledPlatform != nil || event.platform != nil else { return nil }
        return PlatformInfo(planned: event.scheduledPlatform, actual: event.platform)
    }
}

/// Where a running train is right now.
public struct TrainPosition: Codable, Sendable, Hashable {
    public var coordinate: Coordinate
    /// When the train's sensor took this fix (not when it was fetched).
    public var time: Date
    public var speedKmh: Double?
    /// bahn.expert's origin of the fix, e.g. "SENSOR".
    public var source: String?

    /// Fixes are sent every few seconds; an older one means the feed stalled (tunnel, no coverage).
    public func isStale(after seconds: TimeInterval = 120, now: Date = .now) -> Bool {
        now.timeIntervalSince(time) > seconds
    }
}

/// bahn.expert's public API. Given only category, number and date it resolves the journey, finds the
/// first stop and asks for the coach sequence there - what bahn.expert's own web page does, but
/// without a browser. Works for days ahead (planned formation), unlike bahn.de's coach sequence.
public struct BahnExpertClient: Sendable {
    public static let baseURL = URL(string: "https://bahn.expert")!
    /// Deutsche Bahn's administration ID.
    public static let dbAdministration = "80"

    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient(timeout: 12)) {
        self.http = http
    }

    public static func pageURL(category: String, number: String, date: String, administration: String = dbAdministration) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/details/\("\(category) \(number)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")/\(date)T12:00:00.000Z"
        components?.queryItems = [.init(name: "administration", value: administration)]
        return components?.url
    }

    // MARK: Wire types

    struct Envelope<T: Decodable>: Decodable { var json: T }

    struct FoundJourney: Decodable {
        struct Stop: Decodable { struct Place: Decodable { var evaNumber: String }; var stopPlace: Place }
        struct Train: Decodable { var category: String?; var journeyNumber: Int? }
        var journeyId: String
        var train: Train?
        var firstStop: Stop?
    }

    struct Details: Decodable {
        struct Stop: Decodable {
            struct Place: Decodable { var evaNumber: String; var name: String? }
            struct Event: Decodable {
                var scheduledTime: Date
                var time: Date?
                var scheduledPlatform: String?
                var platform: String?
            }
            var stopPlace: Place
            var arrival: Event?
            var departure: Event?
            /// The stop was dropped from this run today (e.g. after a diversion) — the counterpart to
            /// `additional` below. Neither is carried by Transitous' or Träwelling's own schedule-only
            /// timetable data.
            var cancelled: Bool?
            /// An unscheduled stop the train picked up today ("Zusatzhalt"), not part of its regular
            /// timetable.
            var additional: Bool?
        }
        struct Train: Decodable { var category: String?; var journeyNumber: Int?; var admin: String? }
        var stops: [Stop]
        var train: Train?
    }

    struct SequenceResponse: Decodable {
        struct Sequence: Decodable {
            struct Group: Decodable {
                struct Baureihe: Decodable { var identifier: String?; var baureihe: String?; var name: String? }
                struct Coach: Decodable {}
                var name: String?
                var originName: String?
                var destinationName: String?
                var journeyNumber: Int?
                var baureihe: Baureihe?
                var coaches: [Coach]?
            }
            var groups: [Group]
        }
        var isRealtime: Bool
        var source: String?
        var sequence: Sequence?
    }

    struct PositionResponse: Decodable {
        var latitude: Double
        var longitude: Double
        var time: Date
        var speed: Double?
        var metaSource: String?
    }

    // MARK: Lookup

    /// - Parameters:
    ///   - category: e.g. "ICE".
    ///   - number: e.g. "2374".
    ///   - date: calendar day of the train's *initial* departure, `yyyy-MM-dd`.
    /// - Returns: nil if bahn.expert knows the train but has no coach sequence for it.
    /// - Throws: `TransitError.notFound` if no such journey exists on that day.
    public func trainType(category: String, number: String, date: String,
                          administration: String = BahnExpertClient.dbAdministration) async throws -> TrainTypeLookup? {
        let category = category.uppercased()
        let (journey, journeyNumber) = try await resolveJourney(category: category, number: number, date: date, administration: administration)

        let details: Details = try await call("journey/detailsByJourneyId", input: ["json": journey.journeyId])
        guard let firstStop = details.stops.first, let departure = firstStop.departure?.scheduledTime else { return nil }

        // Live data is keyed by the administration that runs the train, which can differ from the
        // one searched (e.g. an ICE run by SBB inside Switzerland).
        let runningAdministration = details.train?.admin ?? administration
        let plannedDeparture = JSONDecoding.isoString(departure)
        let sequenceResponse: SequenceResponse = try await call("coachSequence/departureSequence", input: [
            "json": [
                "evaNumber": firstStop.stopPlace.evaNumber, "plannedDeparture": plannedDeparture,
                "initialDeparture": plannedDeparture, "journeyNumber": journeyNumber,
                "category": category, "administration": runningAdministration,
            ],
            "meta": [["date", "plannedDeparture"], ["date", "initialDeparture"]],
        ])
        guard let sequence = sequenceResponse.sequence, !sequence.groups.isEmpty else { return nil }

        // Split trains (e.g. ICE 950 + ICE 940 coupled up to Hamm) list every half; keep the ones that
        // run as the requested train so the other half's series doesn't leak in.
        let own = sequence.groups.filter { $0.journeyNumber == journeyNumber }
        let groups = (own.isEmpty ? sequence.groups : own).map { group in
            TrainTypeLookup.Group(
                seriesName: group.baureihe?.name, baureihe: group.baureihe?.baureihe,
                unitNumber: sequenceResponse.isRealtime ? Self.unitNumber(from: group.name) : nil,
                origin: group.originName, destination: group.destinationName, coachCount: group.coaches?.count ?? 0)
        }
        return TrainTypeLookup(category: category, number: number, date: date, administration: administration,
                               groups: groups, status: sequenceResponse.isRealtime ? .realtime : .planned,
                               source: sequenceResponse.source, retrievedAt: .now)
    }

    /// Looks up a leg's train on the day it departs (Berlin time). Only DB long-distance categories.
    public func trainType(for leg: Leg) async throws -> TrainTypeLookup? {
        guard let ref = Self.trainReference(for: leg.line) else { return nil }
        return try await trainType(category: ref.category, number: ref.number, date: Self.berlinDay(leg.departure.planned))
    }

    /// Live position of a running train, from the train's own GPS sensor as relayed by bahn.expert.
    /// - Returns: nil while the train is not underway (before departure or after arrival).
    /// - Throws: `TransitError.notFound` if no such journey exists on that day.
    public func position(category: String, number: String, date: String,
                         administration: String = BahnExpertClient.dbAdministration) async throws -> TrainPosition? {
        let category = category.uppercased()
        let (journey, _) = try await resolveJourney(category: category, number: number, date: date, administration: administration)
        do {
            let wire: PositionResponse = try await call("journey/journeyPosition", input: ["json": journey.journeyId])
            return TrainPosition(coordinate: Coordinate(latitude: wire.latitude, longitude: wire.longitude),
                                 time: wire.time, speedKmh: wire.speed, source: wire.metaSource)
        } catch TransitError.notFound {
            return nil
        }
    }

    /// Live position of a leg's train. Only ICE, since that is what carries the position sensor feed.
    /// A train that left before midnight runs under the previous day's date, so that day is tried too
    /// for departures in the early hours.
    public func position(for leg: Leg) async throws -> TrainPosition? {
        guard let ref = Self.trainReference(for: leg.line), ref.category == "ICE" else { return nil }
        var days = [Self.berlinDay(leg.departure.planned)]
        if Self.berlinHour(leg.departure.planned) < 6 {
            days.append(Self.berlinDay(leg.departure.planned.addingTimeInterval(-86_400)))
        }
        for day in days {
            do {
                if let position = try await position(category: ref.category, number: ref.number, date: day) { return position }
            } catch TransitError.notFound {
                continue
            }
        }
        return nil
    }

    /// The realtime stop sequence for `leg`'s train on the day it departs, including any Zusatzhalt
    /// (unscheduled stop) or stop it skipped — data Transitous doesn't carry at all (see
    /// `TimetablesClient` for the same gap on delays/platforms) since it only ever has the planned
    /// schedule. `nil` if `leg`'s train isn't a DB long-distance category bahn.expert can look up at
    /// all; throws `TransitError.notFound` if it is one but no such journey exists on that day.
    public func journeyStops(for leg: Leg) async throws -> [JourneyStop]? {
        guard let ref = Self.trainReference(for: leg.line) else { return nil }
        let date = Self.berlinDay(leg.departure.planned)
        let (journey, _) = try await resolveJourney(category: ref.category, number: ref.number, date: date, administration: Self.dbAdministration)
        let details: Details = try await call("journey/detailsByJourneyId", input: ["json": journey.journeyId])
        return details.stops.map(JourneyStop.init)
    }

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

    /// "ICE 950" → ("ICE", "950"); nil for anything that is not a DB long-distance train.
    public static func trainReference(for line: Line?) -> (category: String, number: String)? {
        guard let line, let number = line.number,
              let category = line.name.split(separator: " ").first.map(String.init)?.uppercased(),
              ["ICE", "IC", "EC", "ECE"].contains(category) else { return nil }
        return (category, number)
    }

    // MARK: Helpers

    private func resolveJourney(category: String, number: String, date: String,
                                administration: String) async throws -> (FoundJourney, Int) {
        guard let journeyNumber = Int(number), Self.isValidDay(date) else {
            throw TransitError.invalidInput("Zugnummer oder Datum ungültig.")
        }
        let found: [FoundJourney] = try await call("journey/find", input: [
            "json": [
                "journeyNumber": journeyNumber, "administration": administration, "category": category,
                "initialDepartureDate": "\(date)T12:00:00.000Z", "withOEV": true, "limit": 1,
            ] as [String: Any],
            "meta": [["date", "initialDepartureDate"]],
        ])
        // A journey ID can resolve to a different train than asked for, so verify what came back.
        guard let journey = found.first(where: {
            $0.train?.journeyNumber == journeyNumber && $0.train?.category?.uppercased() == category
        }) else { throw TransitError.notFound("\(category) \(number)") }
        return (journey, journeyNumber)
    }

    /// Group names for live data look like "ICE9465"; planned ones like "373-planned".
    static func unitNumber(from groupName: String?) -> String? {
        guard let groupName else { return nil }
        let letters = groupName.prefix { $0.isLetter }
        let digits = groupName.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let trimmed = String(digits.drop { $0 == "0" })
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Calendar day of `date` in Europe/Berlin as `yyyy-MM-dd`, the form bahn.expert expects.
    public static func berlinDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func berlinHour(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar.component(.hour, from: date)
    }

    /// Rejects malformed dates and impossible ones like 2026-02-31.
    static func isValidDay(_ day: String) -> Bool {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, day.count == 10 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// bahn.expert answers requests without a `Referer` from its own site with an empty `206`
    /// (it did not until 2026-09-20), so every call identifies where the API is meant to be used from.
    static func request(procedure: String, input: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/orpc/\(procedure)"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: input)
        return request
    }

    private func call<T: Decodable>(_ procedure: String, input: [String: Any]) async throws -> T {
        let request = try Self.request(procedure: procedure, input: input)
        do {
            return try await http.send(request, as: Envelope<T>.self).json
        } catch TransitError.http(let status, _) where status == 404 {
            throw TransitError.notFound(procedure)
        }
    }
}
