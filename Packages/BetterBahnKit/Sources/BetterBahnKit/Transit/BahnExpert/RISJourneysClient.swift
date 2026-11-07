import Foundation

/// DB's official RIS::Journeys (DB API Marketplace), through our server (`Server/bahnde-proxy`, which adds the
/// key): a run by its number and a run's stops with DB's plan, live times and platforms. bahn.expert answers
/// these from RIS::Journeys too (the same journey and stop IDs), so `BahnExpertClient` asks here first and
/// only asks bahn.expert when this fails. Compared on 12 running trains (Nov 2026: late, cancelled, abroad,
/// other operators), stops, plan and live times, platforms and cancellations were the same in both.
///
/// The answers are handed over in bahn.expert's shape (`expertFind`, `expertDetails`), so everything reading
/// bahn.expert's runs reads these unchanged.
public struct RISJourneysClient: Sendable {
    /// The server's path for RIS::Journeys, the same as DB's below `apis.deutschebahn.com`.
    static let path = "db/apis/ris-journeys/v2/"
    /// After a failure (server down, key refused), bahn.expert answers for this long without asking here first.
    static let pause: TimeInterval = 120

    let baseURL: URL
    let http: HTTPClient
    let auth: WorkerAuth?
    let health: Health

    /// The app's client: our server, on the app's real session; nil without a server.
    public static let shared: RISJourneysClient? = BahnDeProxy.baseURL.map { RISJourneysClient(serverURL: $0) }

    public init(serverURL: URL, http: HTTPClient = HTTPClient(timeout: 8), auth: WorkerAuth? = nil, health: Health = Health()) {
        self.baseURL = serverURL.appending(path: Self.path)
        self.http = http
        self.auth = http.workerAuth(auth)
        self.health = health
    }

    public actor Health {
        var failedAt: Date?
        public init() {}
        func available(now: Date = .now) -> Bool {
            failedAt.map { now.timeIntervalSince($0) > RISJourneysClient.pause } ?? true
        }
        func markFailed() { failedAt = .now }
        func markOK() { failedAt = nil }
    }

    // MARK: Wire types

    struct FindResponse: Decodable {
        var journeys: [Found]
    }

    struct Found: Decodable {
        var journeyID: String
        var info: Info
        struct Info: Decodable {
            var origin: Place?
            var destination: Place?
            var transportAtStart: Transport?
        }
    }

    struct Place: Codable {
        var evaNumber: String?
        var name: String?
        var ifopt: String?
    }

    struct Transport: Decodable {
        var category: String?
        var journeyNumber: Int?
        var line: String?
        var type: String?
        var journeyDescription: String?
        var administration: Administration?
        struct Administration: Decodable { var administrationID: String?; var operatorName: String? }
    }

    struct Details: Decodable {
        var journeyID: String?
        var events: [Event]
    }

    struct Event: Decodable {
        /// "ARRIVAL" or "DEPARTURE".
        var type: String
        var arrivalOrDepartureID: String?
        var stopPlace: Place
        var timeSchedule: String
        var time: String?
        /// "SCHEDULE", "PREVIEW" or "REAL".
        var timeType: String?
        var platform: String?
        var platformSchedule: String?
        var cancelled: Bool?
        var additional: Bool?
        var transport: Transport?
    }

    // MARK: Requests

    /// RIS lists only 20 runs unless asked for more, and a number has many (216 buses, trams and trains with
    /// the number 7 on one day): FLX 1243 wasn't among the first 20.
    static let findLimit = 1000

    /// The runs with `number` starting on `day` (`yyyy-MM-dd`), in bahn.expert's `journey/find` shape. Any
    /// category is asked for: RIS takes it strictly (ODEG's RE 62025 isn't found as "RE"), bahn.expert only as
    /// a hint, so `category` only puts its runs first, then trains before buses and trams. RIS also lists the
    /// day before's run; only `day`'s are kept, its ID starts with the day ("20261103-…").
    func expertFind(number: Int, category: String?, day: String, limit: Int?) async throws -> Data {
        let url = baseURL.appending(path: "find").appending(queryItems: [
            .init(name: "journeyNumber", value: String(number)), .init(name: "date", value: day),
            .init(name: "limit", value: String(Self.findLimit)),
        ])
        let response = try await get(url, as: FindResponse.self)
        return try Self.expertFind(response, category: category, day: day, limit: limit)
    }

    /// A run's stops in bahn.expert's `journey/detailsByJourneyId` shape.
    func expertDetails(journeyId: String) async throws -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !journeyId.isEmpty, journeyId.unicodeScalars.allSatisfy(allowed.contains) else {
            throw TransitError.invalidInput(journeyId)
        }
        let details = try await get(baseURL.appending(path: journeyId), as: Details.self)
        return try Self.expertDetails(details, journeyId: journeyId)
    }

    // MARK: Trips

    /// The run of `category`+`number` that calls at `eva` with its `kind` side planned at `planned` (±2 min), as a
    /// `Trip` with DB's stops, times and platforms. nil when RIS has no such run.
    public func trip(category: String, number: String, eva: String, planned: Date, kind: BoardKind) async throws -> Trip? {
        guard let journeyNumber = Int(number) else { return nil }
        let day = BahnDeClient.berlinDay(planned)
        let url = baseURL.appending(path: "find").appending(queryItems: [
            .init(name: "journeyNumber", value: String(journeyNumber)), .init(name: "date", value: day),
            .init(name: "limit", value: String(Self.findLimit)),
        ])
        let prefix = day.replacingOccurrences(of: "-", with: "") + "-"
        let wanted = category.uppercased()
        let runs = try await get(url, as: FindResponse.self).journeys
            .filter { $0.journeyID.hasPrefix(prefix) && $0.info.transportAtStart?.journeyNumber == journeyNumber }
            .sorted { ($0.info.transportAtStart?.category?.uppercased() == wanted ? 0 : 1) < ($1.info.transportAtStart?.category?.uppercased() == wanted ? 0 : 1) }
        let side = kind == .departures ? "DEPARTURE" : "ARRIVAL"
        for run in runs.prefix(3) {
            let details = try await get(baseURL.appending(path: run.journeyID), as: Details.self)
            let calls = details.events.contains { event in
                event.type == side && event.stopPlace.evaNumber == eva
                    && JSONDecoding.parseISODate(event.timeSchedule).map { abs($0.timeIntervalSince(planned)) <= 120 } == true
            }
            if calls { return Self.trip(id: run.journeyID, from: details) }
        }
        return nil
    }

    /// The run `journeyId` (a RIS journey ID, "20261104-…") as a `Trip`.
    public func trip(journeyId: String) async throws -> Trip {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !journeyId.isEmpty, journeyId.unicodeScalars.allSatisfy(allowed.contains) else { throw TransitError.invalidInput(journeyId) }
        return Self.trip(id: journeyId, from: try await get(baseURL.appending(path: journeyId), as: Details.self))
    }

    /// A RIS journey ID: its day and a UUID.
    public static func isJourneyId(_ id: String) -> Bool {
        id.wholeMatch(of: /\d{8}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil
    }

    static func trip(id: String, from details: Details) -> Trip {
        var stopovers: [Stopover] = []
        for event in details.events {
            guard let planned = JSONDecoding.parseISODate(event.timeSchedule) else { continue }
            let live = event.timeType == "REAL" || event.timeType == "PREVIEW"
            let time = TimeInfo(planned: planned, actual: live ? event.time.flatMap(JSONDecoding.parseISODate) : nil)
            let platform = PlatformInfo(planned: event.platformSchedule, actual: event.platform)
            let eva = event.stopPlace.evaNumber ?? ""
            if event.type == "DEPARTURE", let last = stopovers.indices.last, stopovers[last].station.id == eva, stopovers[last].departure == nil {
                stopovers[last].departure = time
                stopovers[last].departurePlatform = platform
                stopovers[last].departureCancelled = event.cancelled == true
                continue
            }
            let station = Station(id: eva, name: event.stopPlace.name ?? eva, coordinate: nil, evaNumber: eva, source: .bahnDe)
            var stopover = Stopover(station: station, arrival: event.type == "ARRIVAL" ? time : nil,
                                    departure: event.type == "DEPARTURE" ? time : nil,
                                    arrivalPlatform: event.type == "ARRIVAL" ? platform : nil,
                                    departurePlatform: event.type == "DEPARTURE" ? platform : nil,
                                    cancelled: false, isAdditional: event.additional == true)
            stopover.arrivalCancelled = event.type == "ARRIVAL" && event.cancelled == true
            stopover.departureCancelled = event.type == "DEPARTURE" && event.cancelled == true
            stopovers.append(stopover)
        }
        let transport = details.events.first?.transport
        let line = transport.map {
            RISRoutingProvider.line(RISRoutingProvider.Transport(type: $0.type, journeyDescription: $0.journeyDescription,
                                                                 category: $0.category, number: $0.journeyNumber, line: $0.line,
                                                                 label: nil, direction: nil),
                                    operatorName: $0.administration?.operatorName)
        }
        return Trip(id: id, line: line, direction: stopovers.last?.station.name, stopovers: stopovers,
                    cancelled: !stopovers.isEmpty && stopovers.allSatisfy(\.cancelled), remarks: [], source: .bahnDe)
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        try await http.get(url, as: type, headers: ["Accept": "application/vnd.de.db.ris+json"], auth: auth)
    }

    // MARK: bahn.expert's shape

    static func expertFind(_ response: FindResponse, category: String?, day: String, limit: Int?) throws -> Data {
        let prefix = day.replacingOccurrences(of: "-", with: "") + "-"
        let wanted = category?.uppercased()
        func rank(_ run: Found) -> Int {
            let transport = run.info.transportAtStart
            let matches = wanted != nil && transport?.category?.uppercased() == wanted
            let isTrain = transport?.type.map(trainTypes.contains) ?? false
            return (matches ? 0 : 2) + (isTrain ? 0 : 1)
        }
        var runs = response.journeys.filter { $0.journeyID.hasPrefix(prefix) }
            .enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        if let limit { runs = Array(runs.prefix(limit)) }
        let json: [[String: Any]] = runs.map { run in
            let transport = run.info.transportAtStart
            var train: [String: Any] = [:]
            train["category"] = transport?.category
            train["journeyNumber"] = transport?.journeyNumber
            train["line"] = transport?.line
            train["transportType"] = transport?.type
            var entry: [String: Any] = ["journeyId": run.journeyID, "train": train]
            entry["firstStop"] = run.info.origin.map { ["stopPlace": place($0)] }
            entry["lastStop"] = run.info.destination.map { ["stopPlace": place($0)] }
            return entry
        }
        return try JSONSerialization.data(withJSONObject: ["json": json])
    }

    /// One stop per arrival/departure pair, in order: a departure joins the stop just before when it is the
    /// same station and that stop has no departure yet.
    static func expertDetails(_ details: Details, journeyId: String) throws -> Data {
        var stops: [[String: Any]] = []
        var lastEva: String?
        for event in details.events {
            let side = event.type == "ARRIVAL" ? "arrival" : "departure"
            if side == "departure", let last = stops.indices.last, lastEva == event.stopPlace.evaNumber, stops[last]["departure"] == nil {
                stops[last]["departure"] = expertEvent(event)
                continue
            }
            stops.append(["stopPlace": place(event.stopPlace), side: expertEvent(event)])
            lastEva = event.stopPlace.evaNumber
        }
        var train: [String: Any] = [:]
        if let transport = details.events.first?.transport {
            train["category"] = transport.category
            train["journeyNumber"] = transport.journeyNumber
            train["admin"] = transport.administration?.administrationID
            train["operator"] = transport.administration?.operatorName
            train["transportType"] = transport.type
            train["name"] = transport.journeyDescription
        }
        return try JSONSerialization.data(withJSONObject: ["json": ["journeyId": journeyId, "stops": stops, "train": train]])
    }

    static let trainTypes: Set<String> = ["HIGH_SPEED_TRAIN", "INTERCITY_TRAIN", "INTER_REGIONAL_TRAIN", "REGIONAL_TRAIN", "CITY_TRAIN"]

    static func expertEvent(_ event: Event) -> [String: Any] {
        var json: [String: Any] = ["scheduledTime": event.timeSchedule, "isRealTime": event.timeType == "REAL" || event.timeType == "PREVIEW"]
        json["time"] = event.time
        json["scheduledPlatform"] = event.platformSchedule.flatMap { $0.isEmpty ? nil : $0 }
        json["platform"] = event.platform.flatMap { $0.isEmpty ? nil : $0 }
        json["id"] = event.arrivalOrDepartureID
        if event.cancelled == true { json["cancelled"] = true }
        if event.additional == true { json["additional"] = true }
        return json
    }

    static func place(_ place: Place) -> [String: Any] {
        var json: [String: Any] = [:]
        json["evaNumber"] = place.evaNumber
        json["name"] = place.name
        json["ifopt"] = place.ifopt.flatMap { $0.isEmpty ? nil : $0 }
        return json
    }
}
