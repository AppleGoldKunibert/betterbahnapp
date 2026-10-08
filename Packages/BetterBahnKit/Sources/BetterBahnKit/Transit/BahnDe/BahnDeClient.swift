import Foundation

/// Rolling stock of a train, e.g. "ICE 3neo" with Tz 8030 + 8005.
public struct TrainFormation: Codable, Sendable, Hashable {
    public struct Unit: Codable, Sendable, Hashable {
        /// Marketing name of the series, e.g. "ICE 4".
        public var model: String?
        /// Triebzug number, e.g. "9465".
        public var number: String?
        /// The trainset's christened name ("Taufname"), e.g. "Bundesrepublik Deutschland".
        public var name: String?

        public init(model: String?, number: String?, name: String? = nil) {
            self.model = model
            self.number = number
            self.name = name
        }
    }

    public var units: [Unit]

    public init(units: [Unit]) {
        self.units = units
    }

    /// "ICE 3neo" or "ICE 3neo + ICE 4". Redesigned ICE 3neo are named by their Tz here as well, so
    /// formations remembered before that rule existed show "ICE 3neo Redesign" too.
    public var modelSummary: String? {
        let models = units.compactMap { TrainModel.name($0.model, unit: $0.number) }
        guard !models.isEmpty else { return nil }
        var unique: [String] = []
        for model in models where !unique.contains(model) { unique.append(model) }
        return unique.count == 1 && models.count > 1 ? "\(models.count)× \(unique[0])" : unique.joined(separator: " + ")
    }

    /// "Tz 8030 + 8005"
    public var unitSummary: String? {
        let numbers = units.compactMap(\.number)
        guard !numbers.isEmpty else { return nil }
        return "Tz " + numbers.joined(separator: " + ")
    }

    /// "Tz 9457 „Bundesrepublik Deutschland“ + 9018"
    public var unitDescription: String? {
        let parts = units.compactMap { unit in unit.number.map { number in unit.name.map { "\(number) „\($0)“" } ?? number } }
        guard !parts.isEmpty else { return nil }
        return "Tz " + parts.joined(separator: " + ")
    }

    /// `stored` with `formation` kept for `key` (see `Leg.formationKey`), so a saved journey still
    /// shows which trainsets ran once bahn.de and bahn.expert no longer answer for the train. Only a
    /// formation naming a Tz is kept; nil when there is nothing to change.
    public static func remembering(_ formation: TrainFormation, for key: String,
                                   in stored: [String: TrainFormation]?) -> [String: TrainFormation]? {
        guard formation.unitDescription != nil, stored?[key] != formation else { return nil }
        var updated = stored ?? [:]
        updated[key] = formation
        return updated
    }
}

extension Leg {
    /// Identifies the leg's train run for its remembered formation: the planned departure and arrival,
    /// which stay the same when a refresh renames the train or changes its trip ID.
    public var formationKey: String {
        "\(Int(departure.planned.timeIntervalSince1970))-\(Int(arrival.planned.timeIntervalSince1970))"
    }
}

/// Endpoints of bahn.de's web API: station search, departure boards, journey details and coach
/// sequences — the same ones Travel::Status::DE::DBRIS uses (https://github.com/derf/Travel-Status-DE-DBRIS).
///
/// bahn.de's bot protection blocks Apple's URL loading stack whatever headers are sent, so requests
/// go through our Cloudflare Worker (`Cloudflare/bahnde-proxy`), which mirrors bahn.de's `/web/api/…`
/// paths and sends the DBRIS browser headers itself. Requests carry the app's App Attest token
/// (`WorkerAuth`). Responses are cached, and a 403/429 (passed through by the Worker) pauses every
/// bahn.de request through the Worker for `BahnDeGate.cooldown` instead of retrying. Meanwhile the app
/// asks bahn.de from the phone itself, in a hidden browser (`BahnDeBrowserFallback`), so one block of
/// the shared Worker doesn't take bahn.de's data away from every user.
public struct BahnDeClient: Sendable {
    public static let baseURL = URL(string: "https://betterbahn2.betterbahn.workers.dev/web/api")!
    /// Deutsche Bahn's administration ID.
    public static let dbAdministration = "80"
    /// Categories whose coach sequence and journey details bahn.de has (Railjets included).
    static let longDistanceCategories: Set<String> = ["ICE", "IC", "EC", "ECE", "RJ", "RJX"]
    /// Regional categories bahn.de takes for a coach-sequence request. It has sequences for DB Regio's
    /// trains (other operators answer 404) and refuses unknown categories with a 403, which would
    /// pause every bahn.de request, so any other regional name is asked for as "RB".
    static let regionalCategories: Set<String> = ["RE", "RB", "IRE"]

    let http: HTTPClient
    let gate: BahnDeGate
    let auth: WorkerAuth?
    /// Asks bahn.de from the phone when the Worker is blocked; none in widgets and tests.
    let browser: BahnDeBrowserFallback?

    /// `auth` and `browser` default to the shared ones on the app's real session and none on others (tests).
    public init(http: HTTPClient = HTTPClient(timeout: 8), gate: BahnDeGate = .shared, auth: WorkerAuth? = nil,
                browser: BahnDeBrowserFallback? = nil) {
        self.http = http
        self.gate = gate
        self.auth = http.workerAuth(auth)
        self.browser = browser ?? (http.session === URLSession.shared ? .shared : nil)
    }

    /// Caches are only shared on the app's real session; a client on a custom session (tests,
    /// mocks) must never see another client's stored responses.
    var usesSharedCaches: Bool { http.session === URLSession.shared }

    struct Location: Decodable {
        var extId: String?
        var name: String
        var lat: Double?
        var lon: Double?
        var type: String?
        /// e.g. ["ICE", "EC_IC", "REGIONAL", "BUS"].
        var products: [String]?
    }

    /// A station from bahn.de's search, and whether trains call there.
    struct Candidate {
        var station: Station
        var hasTrains: Bool
    }

    public func searchStations(_ query: String) async throws -> [Station] {
        try await candidates(query).map(\.station)
    }

    func candidates(_ query: String) async throws -> [Candidate] {
        let url = Self.baseURL.appending(path: "reiseloesung/orte").appending(queryItems: [
            .init(name: "suchbegriff", value: query),
            .init(name: "typ", value: "ALL"),
            .init(name: "limit", value: "10"),
        ])
        let locations = try await get(url, as: [Location].self)
        return locations.compactMap { location in
            guard location.type == "ST", let eva = location.extId else { return nil }
            let coordinate = location.lat.flatMap { lat in location.lon.map { Coordinate(latitude: lat, longitude: $0) } }
            let hasTrains = (location.products ?? []).contains { Self.trainProducts.contains($0) }
            return Candidate(station: Station(id: eva, name: location.name, coordinate: coordinate, evaNumber: eva, source: .bahnDe),
                             hasTrains: hasTrains)
        }
    }

    static let trainProducts: Set<String> = ["ICE", "EC_IC", "IR", "REGIONAL", "SBAHN"]

    /// EVA number for a station from any source (nearest match by name).
    public func evaNumber(for station: Station) async throws -> String? {
        if let eva = station.evaNumber { return eva }
        return Self.bestEVA(for: station, among: try await candidates(station.name))
    }

    /// The candidate that is `station`'s railway station. Everything asking for an EVA number wants
    /// the railway station (Timetables, boards, coach sequences), so stops without trains only count
    /// when there's nothing else.
    static func bestEVA(for station: Station, among all: [Candidate]) -> String? {
        // bahn.de also lists meta stations that bundle a station with its bus stops (e.g. "Westerland
        // Bahnhof/ZOB, Sylt", 709827, right next to "Westerland(Sylt)", 8006369). Their IDs aren't
        // EVA numbers — Timetables has no platforms for them — and real ones have 7 digits.
        let real = all.filter { $0.station.id.count == 7 }
        let pool = real.isEmpty ? all : real
        let withTrains = pool.filter(\.hasTrains)
        let candidates = (withTrains.isEmpty ? pool : withTrains).map(\.station)
        // A big interchange's own search also lists its separate entrances/exits a few hundred
        // meters apart under their own EVA (e.g. Berlin Gesundbrunnen's search also returns
        // "Gesundbrunnen Bahnhof Badstr.", which has no Timetables ("IRIS") schedule of its own) -
        // nearest-by-distance alone can pick one of those over the actual station, so a name match
        // is tried first.
        let target = Station.normalize(station.displayName)
        if let exact = candidates.first(where: { Station.normalize($0.displayName) == target }) {
            return exact.evaNumber
        }
        if let coordinate = station.coordinate {
            let nearest = candidates
                .compactMap { c in c.coordinate.map { (c, $0.distance(to: coordinate)) } }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 < 1_500 { return nearest.0.evaNumber }
        }
        return candidates.first?.evaNumber
    }

    // MARK: Coach sequence

    struct SequenceResponse: Decodable {
        struct Group: Decodable {
            struct Transport: Decodable {
                struct Destination: Decodable { var name: String? }
                var category: String?
                var number: Int?
                var destination: Destination?
            }
            struct Vehicle: Decodable {
                struct VehicleType: Decodable {
                    var category: String?
                    var constructionType: String?
                    var hasFirstClass: Bool?
                    var hasEconomyClass: Bool?
                }
                struct Amenity: Decodable { var type: String?; var status: String?; var amount: Int? }
                struct Position: Decodable { var start: Double?; var end: Double?; var sector: String? }
                var type: VehicleType?
                /// UIC number, 12 digits, e.g. "938054010021" for a BR 401 power car.
                var vehicleID: String?
                /// Coach number shown to passengers, e.g. 21.
                var wagonIdentificationNumber: Int?
                /// "OPEN" or "CLOSED".
                var status: String?
                var amenities: [Amenity]?
                var platformPosition: Position?
            }
            /// e.g. "ICE0169" → Tz 169.
            var name: String?
            var transport: Transport?
            var vehicles: [Vehicle]?
        }
        struct Platform: Decodable {
            struct Sector: Decodable { var name: String?; var start: Double?; var end: Double? }
            var name: String?
            var start: Double?
            var end: Double?
            var sectors: [Sector]?
        }
        var groups: [Group]?
        var departurePlatform: String?
        var platform: Platform?
        /// e.g. "DIFFERS_FROM_SCHEDULE".
        var sequenceStatus: String?
    }

    /// Everything the coach-sequence request needs: the train plus a stop where it still departs.
    public struct FormationRequest: Hashable, Sendable {
        public var category: String
        public var number: String
        public var station: Station
        /// Scheduled departure at `station`.
        public var plannedDeparture: Date
        /// Trains coupled to it for the whole ride (`Line.coupledTrains`), whose trainsets count as its own.
        public var coupledNumbers: [String]
        /// The train's stops before `station`, from its first one, when known (a whole train run);
        /// they tell where it changed direction, for vagonweb's plan.
        public var stopsBefore: [String]?
        /// The train run, to load its stops when `stopsBefore` is unknown (a leg starts mid-run).
        public var tripId: String?
        public var tripSource: DataSource?

        public init(category: String, number: String, station: Station, plannedDeparture: Date, coupledNumbers: [String] = [],
                    stopsBefore: [String]? = nil, tripId: String? = nil, tripSource: DataSource? = nil) {
            self.coupledNumbers = coupledNumbers
            self.category = category
            self.number = number
            self.station = station
            self.plannedDeparture = plannedDeparture
            self.stopsBefore = stopsBefore
            self.tripId = tripId
            self.tripSource = tripSource
        }
    }

    /// bahn.de only has the coach sequence for departures in the coming hours (late in the evening it
    /// already had the next morning's), so later ones aren't asked for at all and go to bahn.expert.
    public static let formationLookahead: TimeInterval = 12 * 3600

    /// The request for `line`'s formation at the first of `stops` where it still departs, if that
    /// departure is soon enough for bahn.de to know the coach sequence (see `formationLookahead`).
    /// Without `lookahead` any later departure counts too (for vagonweb's planned Wagenreihung).
    /// - Parameter wholeRun: `stops` start at the train's first stop, so the ones before the request's
    ///   station are its `stopsBefore`.
    public static func formationRequest(line: Line?, stops: [(station: Station, departure: TimeInfo?)], wholeRun: Bool = false,
                                        now: Date = .now, lookahead: TimeInterval? = formationLookahead) -> FormationRequest? {
        guard let ref = sequenceReference(for: line) else { return nil }
        guard let index = stops.firstIndex(where: { $0.departure.map { $0.best >= now.addingTimeInterval(-60) } ?? false }),
              let departure = stops[index].departure,
              lookahead.map({ departure.planned <= now.addingTimeInterval($0) }) ?? true else { return nil }
        return FormationRequest(category: ref.category, number: ref.number, station: stops[index].station, plannedDeparture: departure.planned,
                                coupledNumbers: line?.coupledNumbers ?? [],
                                stopsBefore: wholeRun ? stops[..<index].map(\.station.name) : nil)
    }

    public static func formationRequest(for leg: Leg, now: Date = .now, lookahead: TimeInterval? = formationLookahead) -> FormationRequest? {
        guard !leg.cancelled else { return nil }
        let stops = [(station: leg.origin, departure: Optional(leg.departure))]
            + leg.stopovers.filter { !$0.cancelled }.map { (station: $0.station, departure: $0.departure) }
        var request = formationRequest(line: leg.line, stops: stops, now: now, lookahead: lookahead)
        request?.tripId = leg.tripId
        request?.tripSource = leg.source
        return request
    }

    public static func formationRequest(for trip: Trip, now: Date = .now, lookahead: TimeInterval? = formationLookahead) -> FormationRequest? {
        formationRequest(line: trip.line, stops: trip.stopovers.filter { !$0.cancelled }.map { (station: $0.station, departure: $0.departure) },
                         wholeRun: true, now: now, lookahead: lookahead)
    }

    /// The names of `trip`'s stops before `station` (found by id, else by name), for a request made
    /// from a leg (`FormationRequest.stopsBefore`); nil when the station isn't one of its stops.
    public static func stopsBefore(_ station: Station, in trip: Trip) -> [String]? {
        let names = trip.stopovers.map(\.station.name)
        guard let index = trip.stopovers.firstIndex(where: { $0.station.id == station.id })
                ?? trip.stopovers.firstIndex(where: { VagonwebClient.stationKey($0.station.name) == VagonwebClient.stationKey(station.name) })
        else { return nil }
        return Array(names[..<index])
    }

    /// Formation of a DB long-distance train at its departure from the request's station.
    /// - Returns: nil if bahn.de has no coach sequence for it (yet).
    /// - Throws: `TransitError.rateLimited` while bahn.de is blocking requests.
    public func formation(_ request: FormationRequest) async throws -> TrainFormation? {
        guard let formation = try await coachSequence(request)?.formation, !formation.units.isEmpty else { return nil }
        return formation
    }

    /// Formation of a leg's train at the first stop where it still departs.
    public func formation(for leg: Leg) async throws -> TrainFormation? {
        guard let request = Self.formationRequest(for: leg) else { return nil }
        return try await formation(request)
    }

    /// Coach sequence ("Wagenreihung") of a DB long-distance train at its departure from the
    /// request's station. The same request as `formation(_:)`, so both share one response.
    /// - Returns: nil if bahn.de has no coach sequence for it (yet).
    /// - Throws: `TransitError.rateLimited` while bahn.de is blocking requests.
    public func coachSequence(_ request: FormationRequest) async throws -> CoachSequence? {
        guard usesSharedCaches else { return try await fetchCoachSequence(request) }
        return try await Self.sequenceCache.value(for: Self.sequenceKey(request), maxAge: Self.formationMaxAge) {
            try await self.fetchCoachSequence(request)
        }
    }

    /// Why bahn.de had no coach sequence for `request` the last time it was asked (no EVA number, 404,
    /// an answer without the train's coaches, an error), with what was asked; nil when it had one or
    /// wasn't asked. Shown when the Wagenreihung falls back to vagonweb's plan, since bahn.de's answer
    /// can only be seen from inside the app.
    public func coachSequenceNote(for request: FormationRequest) async -> String? {
        await Self.sequenceNotes.note(for: Self.sequenceKey(request))
    }

    static func sequenceKey(_ request: FormationRequest) -> String {
        "\(request.category) \(([request.number] + request.coupledNumbers).joined(separator: "+"))|\(request.station.id)|\(request.plannedDeparture.timeIntervalSince1970)"
    }

    private static let sequenceCache = ExpiringCache<CoachSequence?>()
    private static let sequenceNotes = SequenceNotes()
    /// A formation rarely changes once published; 10 minutes still catches a late swap.
    static let formationMaxAge: TimeInterval = 10 * 60

    private func fetchCoachSequence(_ request: FormationRequest) async throws -> CoachSequence? {
        let key = Self.sequenceKey(request)
        let asked = "\(request.category) \(request.number), \(Self.utcTimestamp(request.plannedDeparture))"
        do {
            guard let eva = try await evaNumber(for: request.station) else {
                await Self.sequenceNotes.set("keine EVA-Nummer für \(request.station.name) · \(asked)", for: key)
                return nil
            }
            let candidates = [eva, Self.otherLevel(of: eva)].compactMap(\.self)
            for candidate in candidates {
                guard let response = try await sequenceResponse(request, eva: candidate) else { continue }
                let sequence = Self.coachSequence(from: response, category: request.category, number: Int(request.number),
                                                  coupledNumbers: Set(request.coupledNumbers.compactMap { Int($0) }))
                guard !sequence.coaches.isEmpty || !sequence.formation.units.isEmpty else {
                    await Self.sequenceNotes.set("Antwort ohne Wagen an EVA \(candidate): \(Self.summary(of: response)) · \(asked)", for: key)
                    return nil
                }
                await Self.sequenceNotes.set(nil, for: key)
                return sequence
            }
            await Self.sequenceNotes.set("keine Wagenreihung an EVA \(candidates.joined(separator: " / ")) (404) · \(asked)", for: key)
            return nil
        } catch {
            var reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            // Usually not this request's fault: an earlier answer paused every bahn.de request.
            if case TransitError.rateLimited = error, let block = await gate.blockDescription { reason += " (\(block))" }
            await Self.sequenceNotes.set("\(reason) · \(asked)", for: key)
            throw error
        }
    }

    /// "2 Gruppen, Züge IC 1189, RB 5410": what an answer without usable coaches had.
    static func summary(of response: SequenceResponse) -> String {
        let groups = response.groups ?? []
        let trains = Set(groups.compactMap { group in
            group.transport.map { "\($0.category ?? "?") \($0.number.map(String.init) ?? "?")" }
        }).sorted()
        let vehicles = groups.reduce(0) { $0 + ($1.vehicles?.count ?? 0) }
        return "\(groups.count) Gruppen, \(vehicles) Fahrzeuge, Züge \(trains.isEmpty ? "keine" : trains.joined(separator: ", "))"
    }

    /// nil when bahn.de has no coach sequence for the train at `eva` (404).
    private func sequenceResponse(_ request: FormationRequest, eva: String) async throws -> SequenceResponse? {
        do {
            return try await get(Self.formationURL(request, eva: eva), as: SequenceResponse.self)
        } catch TransitError.http(let status, _) where status == 404 {
            return nil
        }
    }

    /// bahn.de keeps the lower level of Berlin Hbf as a station of its own ("Berlin Hbf (tief)", platforms
    /// 1–8) and only has a coach sequence under the level the train stops at, while station search (and
    /// so `evaNumber(for:)`) only ever finds the upper one. A 404 at one level is retried at the other.
    static let levelTwins = ["8011160": "8098160", "8098160": "8011160"]

    static func otherLevel(of eva: String) -> String? { levelTwins[eva] }

    static func formationURL(_ request: FormationRequest, eva: String) -> URL {
        baseURL.appending(path: "reisebegleitung/wagenreihung/vehicle-sequence").appending(queryItems: [
            .init(name: "administrationId", value: dbAdministration),
            .init(name: "category", value: request.category),
            // The departure's day in Germany: a train leaving Brandenburg at 00:41 is asked for under the
            // new day, although it's still the old one in UTC (bahn.de answers 404 then).
            .init(name: "date", value: berlinDay(request.plannedDeparture)),
            .init(name: "evaNumber", value: eva),
            .init(name: "number", value: request.number),
            .init(name: "time", value: utcTimestamp(request.plannedDeparture)),
        ])
    }

    static func formation(from response: SequenceResponse, category: String, number: Int? = nil,
                          coupledNumbers: Set<Int> = []) -> TrainFormation {
        // Split trains (e.g. ICE 950 + ICE 940 coupled up to Hamm) list every half; keep the ones that
        // run as the requested train (or a train coupled to it for the whole ride) so the other half's
        // trainset doesn't leak in.
        // Every field is optional, like in DBRIS: one odd group mustn't lose the whole formation.
        let wanted = coupledNumbers.union([number].compactMap(\.self))
        let groups = requestedTrainGroups(response.groups ?? [], wanted: wanted)
        // The requested train's own trainset first, then the coupled ones' (Tz 9203 + 9228 for ICE 956).
        let own = groups.filter { $0.transport?.number == number }
            + groups.filter { $0.transport?.number != number && ($0.transport?.number.map(wanted.contains) ?? false) }
        var units: [TrainFormation.Unit] = []
        for group in own.isEmpty ? groups : own {
            let vehicles = group.vehicles ?? []
            let name = group.name ?? ""
            // Locomotive-only groups (e.g. the Vectron of an ICE L) have a vehicle ID as name.
            if !vehicles.isEmpty, vehicles.allSatisfy({ $0.type?.category == "LOCOMOTIVE" }) { continue }
            let carriages = vehicles.map { Carriage(vehicleID: $0.vehicleID, constructionType: $0.type?.constructionType) }
            let types = vehicles.compactMap { $0.type?.constructionType }
            let model = TrainModel.detect(carriages, category: category).map(\.name)
                ?? Self.model(constructionTypes: types, groupName: name, category: category)
            let trainset = hasTrainsets(category)
            let number = trainset ? unitNumber(from: name) : nil
            let unit = TrainFormation.Unit(model: TrainModel.name(model, unit: number), number: number,
                                           name: trainset ? trainsetName(from: name) : nil)
            if unit.model != nil || unit.number != nil { units.append(unit) }
        }
        return TrainFormation(units: units)
    }

    /// `groups`, or none when they all name a train number and none of them is `wanted`: then bahn.de
    /// answered with another train's sequence (RE 6 at Itzehoe showed someone else's FLIRTs), and no
    /// type or Wagenreihung beats a wrong one. Groups without numbers still count as the train asked for.
    static func requestedTrainGroups(_ groups: [SequenceResponse.Group], wanted: Set<Int>) -> [SequenceResponse.Group] {
        let numbers = Set(groups.compactMap(\.transport?.number))
        guard !wanted.isEmpty, !numbers.isEmpty, numbers.isDisjoint(with: wanted) else { return groups }
        return groups.filter { $0.transport?.number == nil }
    }

    /// Group names for live data look like "ICE9465" or "ICE0160"; anything else has no Tz.
    static func unitNumber(from groupName: String) -> String? {
        let letters = groupName.prefix { $0.isLetter }
        let digits = groupName.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let trimmed = String(digits.drop { $0 == "0" })
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Taufname of an ICE/ICD trainset, from its group name like "ICE0169".
    static func trainsetName(from groupName: String) -> String? {
        guard groupName.hasPrefix("ICE") || groupName.hasPrefix("ICD"),
              let number = unitNumber(from: groupName).flatMap(Int.init) else { return nil }
        return TrainsetNames.byUnit[number]
    }

    /// Fallback when the vehicles' UIC numbers are inconclusive: maps DB construction types
    /// (e.g. "I4081", "I1412") to series names.
    static func model(constructionTypes: [String], groupName: String, category: String) -> String? {
        var classes = Set<String>()
        var hasTalgo = false
        for type in constructionTypes {
            guard let prefix = type.first else { continue }
            let digits = String(type.dropFirst())
            if prefix == "R", digits.hasPrefix("89") { hasTalgo = true }
            guard prefix == "I", digits.count == 4 else { continue }
            // "4080" → 408, "1412" → 412, "0812" → 812, "8010" → 801
            let first = digits.first!
            classes.insert(["0", "1", "2", "9"].contains(first) ? String(digits.dropFirst().prefix(3)) : String(digits.prefix(3)))
        }
        let map: [(Set<String>, String)] = [
            (["401", "801", "802", "803", "804"], "ICE 1"),
            (["402", "805", "806", "807", "808"], "ICE 2"),
            (["403", "406"], "ICE 3"),
            (["407"], "ICE 3 Velaro"),
            (["408"], "ICE 3neo"),
            (["411", "415"], "ICE T"),
            (["412", "812", "813"], "ICE 4"),
        ]
        for (set, name) in map where !set.isDisjoint(with: classes) { return name }
        if hasTalgo { return "ICE L" }
        if category == "IC" || category == "EC" {
            if groupName.hasPrefix("ICD") { return "IC 2 Twindexx" }
            if constructionTypes.contains(where: { $0.contains("4110") }) { return "IC 2 KISS" }
            return "IC 1"
        }
        return nil
    }

    // MARK: Helpers

    /// "ICE 950" → ("ICE", "950"); nil for anything that is not a DB long-distance train.
    public static func trainReference(for line: Line?) -> (category: String, number: String)? {
        guard let line, let number = line.number,
              let category = line.name.split(separator: " ").first.map(String.init)?.uppercased(),
              longDistanceCategories.contains(category) else { return nil }
        return (category, number)
    }

    /// A regional train by its run number ("RE 5" running as 4530 → ("RE", "4530")). Transitous only
    /// has that number as the trip's short name, so lines without it can't be looked up.
    static func regionalReference(for line: Line?, products: Set<Product>) -> (category: String, number: String)? {
        guard let line, products.contains(line.product), let number = line.tripNumber else { return nil }
        let category = line.name.prefix { $0.isLetter }.uppercased()
        return (category.isEmpty ? "RB" : category, number)
    }

    /// The train to ask bahn.de's coach sequence for: long-distance trains, and DB Regio's RE/RB by
    /// their run number.
    public static func sequenceReference(for line: Line?) -> (category: String, number: String)? {
        if let ref = trainReference(for: line) { return ref }
        guard let ref = regionalReference(for: line, products: [.regionalExpress, .regional]) else { return nil }
        return (regionalCategories.contains(ref.category) ? ref.category : "RB", ref.number)
    }

    /// Whether a group's name is a trainset with a Tz number ("ICE9457"). Regional groups are named
    /// after fleet or vehicle IDs ("RP8352001") that passengers never see.
    static func hasTrainsets(_ category: String) -> Bool {
        longDistanceCategories.contains(category)
    }

    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    /// Calendar day of `date` in Europe/Berlin as `yyyy-MM-dd`.
    public static func berlinDay(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: berlin).year().month().day())
    }

    static func berlinHour(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar.component(.hour, from: date)
    }


    /// `2026-09-29T20:38:00.000Z`, as the coach-sequence request wants it.
    static func utcTimestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    /// Browser agents Travel::Status::DE::DBRIS sends; bahn.de refuses boards and coach sequences
    /// (`OPS_BLOCKED`) to anything that doesn't look like its own web page. The Worker sends its own
    /// copy of these headers; the app keeps sending them so pointing `baseURL` back at bahn.de works.
    static let browserUserAgents = [
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.XXXX.YYY Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 14; SM-S928B/DS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.XXXX.YYY Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 14; Pixel 9 Pro Build/AD1A.240418.003; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.XXXX.YYY Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.XXXX.YYY Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 15; moto g - 2025 Build/V1VK35.22-13-2; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/132.0.XXXX.YYY Mobile Safari/537.36",
        "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.XXXX.YYY Safari/537.36",
    ]

    /// Like DBRIS: one agent picked per launch, with random version digits.
    static let userAgent: String = browserUserAgents.randomElement()!
        .replacing("XXXX", with: String(Int.random(in: 0..<1000)))
        .replacing("YYY", with: String(Int.random(in: 0..<100)))

    /// The headers DBRIS sends with every request.
    static func headers() -> [String: String] {
        [
            "Accept": "application/json",
            "Content-Type": "application/json; charset=utf-8",
            "Origin": "https://www.bahn.de",
            "Referer": "https://www.bahn.de/buchung/fahrplan/suche",
            "User-Agent": userAgent,
            "x-correlation-id": "\(UUID().uuidString.lowercased())_\(UUID().uuidString.lowercased())",
        ]
    }

    /// GET through the Worker and its shared cooldown: while bahn.de is blocking the Worker, nothing is
    /// sent there at all and the phone's browser asks instead, if the app has one.
    func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        if await gate.isBlocked {
            return try await viaBrowser(url, as: type)
        }
        do {
            let value = try await http.get(url, as: type, headers: Self.headers(), auth: auth)
            // The Worker gets through again: the browser's page isn't needed any more.
            await browser?.workerAnswered()
            return value
        } catch let error as TransitError {
            await gate.report(error)
            guard error.isBlocked else { throw error }
            await browser?.workerBlocked()
            return try await viaBrowser(url, as: type)
        }
    }

    /// The same request from the phone's hidden browser on bahn.de (`BahnDeBrowserFallback`), which has
    /// a cooldown of its own. Throws `rateLimited` without one (widgets, tests) or while it is blocked too.
    private func viaBrowser<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        guard let browser, let direct = Self.directURL(for: url) else { throw TransitError.rateLimited }
        let data = try await browser.fetch(direct)
        do {
            return try JSONDecoding.decoder.decode(T.self, from: data)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    /// bahn.de's own address for a request to the Worker, which mirrors its `/web/api/…` paths.
    static func directURL(for url: URL) -> URL? {
        guard url.host() == baseURL.host(), url.path().hasPrefix("/web/api/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        components.host = "www.bahn.de"
        components.port = nil
        return components.url
    }
}

/// The app's hidden browser on bahn.de (set once at launch, `use(_:)`): bahn.de's bot protection lets a
/// real browser engine through where it blocks Apple's URL loading stack, so when the shared Worker is
/// blocked, each phone can still ask for itself, with its own IP address. Has a cooldown of its own for
/// when bahn.de blocks the phone too. Widgets set none.
public actor BahnDeBrowserFallback {
    public static let shared = BahnDeBrowserFallback()

    /// Loads a `https://www.bahn.de/web/api/…` URL in the browser: the HTTP status and the body.
    public typealias Fetch = @Sendable (URL) async throws -> (status: Int, body: Data)

    /// Something for the browser to do without waiting for it: start loading its page, or let it go.
    public typealias Hook = @Sendable () async -> Void

    private var load: Fetch?
    private var prepare: Hook?
    private var release: Hook?
    /// Whether the browser may hold a page (prepared or used since the Worker last answered).
    private(set) var isActive = false
    let gate = BahnDeGate()

    public init(_ load: Fetch? = nil, prepare: Hook? = nil, release: Hook? = nil) {
        self.load = load
        self.prepare = prepare
        self.release = release
    }

    /// `prepare` starts loading the browser's page in the background as soon as the Worker is blocked,
    /// so the first requests don't wait for it; `release` drops the page once the Worker answers again.
    public func use(_ load: @escaping Fetch, prepare: Hook? = nil, release: Hook? = nil) {
        self.load = load
        self.prepare = prepare
        self.release = release
    }

    /// The Worker was blocked: get the page ready, once.
    func workerBlocked() async {
        guard load != nil, !isActive else { return }
        isActive = true
        await prepare?()
    }

    /// The Worker answered: let the page go if the browser has one.
    func workerAnswered() async {
        guard isActive else { return }
        isActive = false
        await release?()
    }

    /// The body of a successful answer; a 404 etc. as `TransitError.http`, a block as `rateLimited`.
    func fetch(_ url: URL) async throws -> Data {
        guard let load else { throw TransitError.rateLimited }
        try await gate.check()
        isActive = true
        do {
            let (status, body) = try await load(url)
            switch status {
            case 200..<300: return body
            case 429: throw TransitError.rateLimited
            default: throw TransitError.http(status: status, body: String(data: body, encoding: .utf8))
            }
        } catch let error as TransitError {
            await gate.report(error, url: url)
            throw error.isBlocked ? TransitError.rateLimited : error
        }
    }
}

/// Pauses every bahn.de request for a while after Akamai answered 403 or 429, so the app never
/// hammers a server that is currently refusing it.
public actor BahnDeGate {
    public static let shared = BahnDeGate()
    public static let cooldown: TimeInterval = 10 * 60

    private var blockedUntil: Date?
    /// What started the current pause: when, the answer and the path, e.g. "10:41 403 OPS_BLOCKED (…/vehicle-sequence)".
    private var blockReason: String?

    public init() {}

    /// Whether bahn.de is currently being left alone after a block.
    public var isBlocked: Bool { blockedUntil.map { $0 > .now } ?? false }

    /// Why bahn.de is being left alone and until when; nil while it isn't.
    public var blockDescription: String? {
        guard isBlocked, let blockedUntil else { return nil }
        let until = blockedUntil.formatted(Date.FormatStyle(timeZone: BahnDeClient.berlin).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return "Pause bis \(until) nach \(blockReason ?? "einer Sperre")"
    }

    func check() throws {
        if isBlocked { throw TransitError.rateLimited }
    }

    func report(_ error: TransitError, url: URL? = nil) {
        guard error.isBlocked else { return }
        blockedUntil = Date.now.addingTimeInterval(Self.cooldown)
        let time = Date.now.formatted(Date.FormatStyle(timeZone: BahnDeClient.berlin).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let answer = switch error {
        case .http(let status, let body): "\(status)\(body.map { " " + Self.excerpt($0) } ?? "")"
        default: "429"
        }
        blockReason = "\(answer) um \(time)\(url.map { " (…/\($0.lastPathComponent))" } ?? "")"
    }

    /// The start of an error body on one line, e.g. bahn.de's `{"code":"OPS_BLOCKED",…}`.
    static func excerpt(_ body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }
}

extension TransitError {
    /// Bot protection or rate limiting rather than a real error of the request itself.
    var isBlocked: Bool {
        switch self {
        case .rateLimited: true
        case .http(let status, _): status == 403
        default: false
        }
    }
}

/// Why bahn.de's coach sequence was missing, per request (`BahnDeClient.coachSequenceNote(for:)`).
actor SequenceNotes {
    private var notes: [String: String] = [:]

    func note(for key: String) -> String? { notes[key] }

    func set(_ note: String?, for key: String) { notes[key] = note }
}

/// Values fetched per key, kept for `maxAge`; concurrent requests for the same key share one fetch.
/// Errors are not cached, so a failed lookup is tried again next time.
actor ExpiringCache<Value: Sendable> {
    struct Entry { let date: Date; let value: Value }
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Value, Error>] = [:]

    func value(for key: String, maxAge: TimeInterval, fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let entry = entries[key], Date.now.timeIntervalSince(entry.date) < maxAge { return entry.value }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await fetch() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let value = try await task.value
        entries[key] = Entry(date: .now, value: value)
        return value
    }
}
