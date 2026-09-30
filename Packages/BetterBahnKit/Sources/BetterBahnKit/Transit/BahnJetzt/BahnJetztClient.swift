import Foundation

/// Where a running train is right now.
public struct TrainPosition: Codable, Sendable, Hashable {
    public var coordinate: Coordinate
    /// When this position was fetched (bahn.jetzt doesn't say when the fix itself was taken).
    public var time: Date
    public var speedKmh: Double?
    /// Where the fix came from, e.g. "bahn.jetzt".
    public var source: String?

    public init(coordinate: Coordinate, time: Date, speedKmh: Double?, source: String?) {
        self.coordinate = coordinate
        self.time = time
        self.speedKmh = speedKmh
        self.source = source
    }

    /// An older position means refreshing has stalled (no network, or the train left the feed).
    public func isStale(after seconds: TimeInterval = 120, now: Date = .now) -> Bool {
        now.timeIntervalSince(time) > seconds
    }
}

/// Live train positions from bahn.jetzt (https://codeberg.org/0x150/bahn.jetzt, used with the
/// operator's permission). Its API has a single list of every running train and no per-train
/// position, so one list fetch serves every leg that is looked up at the same time.
///
/// The API documents no rate limit; the list is fetched at most once per `listMaxAge`, and after a
/// 403/429 nothing is sent for `blockCooldown`.
public struct BahnJetztClient: Sendable {
    public static let baseURL = URL(string: "https://bahn.jetzt/api")!
    /// bahn.jetzt rejects generic agents and asks for one that describes the caller.
    static let userAgent = HTTPClient.identifyingUserAgent

    let http: HTTPClient
    let state: State

    public init(http: HTTPClient = HTTPClient(timeout: 10), state: State = .shared) {
        self.http = http
        self.state = state
    }

    // MARK: Wire types

    struct Journey: Decodable, Sendable {
        struct Details: Decodable, Sendable {
            struct Transport: Decodable, Sendable { var category: String?; var journeyNumber: Int?; var journeyName: String? }
            struct Stop: Decodable, Sendable { var evaNumber: String?; var name: String? }
            var transportAtStart: Transport?
            var destination: Stop?
        }
        /// e.g. "20260929-65771c12-fbc7-3dc8-8f7e-9dbe745ba3a4"; starts with the day the run began.
        var journeyId: String
        /// [longitude, latitude].
        var position: [Double]?
        var speed: Double?
        var name: String?
        var details: Details?
    }

    struct Snapshot: Sendable {
        var journeys: [Journey]
        var fetchedAt: Date
    }

    // MARK: Lookup

    /// The train to look up in bahn.jetzt's list: long-distance trains by their number, regional
    /// trains and S-Bahns by their run number (a regional line's number in Transitous isn't the
    /// train number, so only lines with a run number can be matched).
    public static func reference(for line: Line?) -> (category: String, number: String)? {
        BahnDeClient.trainReference(for: line)
            ?? BahnDeClient.regionalReference(for: line, products: [.regionalExpress, .regional, .suburban])
    }

    /// Whether bahn.jetzt could know this train at all.
    public static func supports(_ line: Line?) -> Bool { reference(for: line) != nil }

    /// What a regional match is checked against, since run numbers are only unique within one country.
    public struct RouteHint: Sendable, Hashable {
        /// The train's final destination (headsign).
        public var destination: String?
        /// The route (track geometry or stops) the train is known to run along.
        public var path: [Coordinate]

        public init(destination: String?, path: [Coordinate]) {
            self.destination = destination
            self.path = path
        }
    }

    /// Live position of a leg's train.
    /// - Returns: nil while the train isn't in bahn.jetzt's list of running trains.
    /// - Throws: `TransitError.rateLimited` while bahn.jetzt is refusing requests.
    public func position(for leg: Leg) async throws -> TrainPosition? {
        let path = leg.geometry.flatMap { $0.isEmpty ? nil : $0 }
            ?? ([leg.origin] + leg.stopovers.map(\.station) + [leg.destination]).compactMap(\.coordinate)
        return try await position(of: leg.line, plannedDeparture: leg.departure.planned,
                                  route: RouteHint(destination: leg.direction, path: path))
    }

    /// Live position of `line`'s run that departs (somewhere along its route) at `plannedDeparture`.
    /// - Parameter route: checked for regional trains (see `isPlausible`); nil skips the check.
    /// - Returns: nil while the train isn't in bahn.jetzt's list of running trains.
    /// - Throws: `TransitError.rateLimited` while bahn.jetzt is refusing requests.
    public func position(of line: Line?, plannedDeparture: Date, route: RouteHint? = nil) async throws -> TrainPosition? {
        guard let ref = Self.reference(for: line), let number = Int(ref.number) else { return nil }
        let snapshot = try await snapshot()
        guard let journey = Self.match(category: ref.category, number: number, departure: plannedDeparture, in: snapshot.journeys),
              let position = journey.position, position.count == 2 else { return nil }
        let coordinate = Coordinate(latitude: position[1], longitude: position[0])
        if let route, !BahnDeClient.longDistanceCategories.contains(ref.category.uppercased()),
           !Self.isPlausible(journey, at: coordinate, for: route) {
            return nil
        }
        return TrainPosition(coordinate: coordinate, time: snapshot.fetchedAt, speedKmh: journey.speed, source: "bahn.jetzt")
    }

    /// How far a regional train may be from its known route and still count, when its destination
    /// doesn't match.
    static let maxDistanceFromRoute: Double = 30_000

    /// Whether a regional match is really this train. Run numbers repeat across countries (Zürich's
    /// S11 runs as 19170, a number German trains use too), so the matched train must either head for
    /// the same destination or be close to the route. The destination alone would miss trains whose
    /// headsign is spelled differently; the distance alone would miss a train still far upstream of
    /// the leg it's looked up for.
    static func isPlausible(_ journey: Journey, at position: Coordinate, for route: RouteHint) -> Bool {
        if route.destination == nil && route.path.isEmpty { return true }
        if let wanted = route.destination.map({ Station.normalize(Station.displayName(for: $0)) }), !wanted.isEmpty,
           let name = journey.details?.destination?.name {
            let actual = Station.normalize(Station.displayName(for: name))
            if !actual.isEmpty, actual == wanted || actual.hasPrefix(wanted) || wanted.hasPrefix(actual) { return true }
        }
        guard let distance = distance(from: position, to: route.path) else { return false }
        return distance <= maxDistanceFromRoute
    }

    /// Shortest distance in meters from `point` to the polyline `path` (flat-earth approximation,
    /// plenty for tens of kilometers); nil for an empty path.
    static func distance(from point: Coordinate, to path: [Coordinate]) -> Double? {
        guard let first = path.first else { return nil }
        guard path.count > 1 else { return point.distance(to: first) }
        let metersPerDegree = 111_320.0
        let cosLat = cos(point.latitude * .pi / 180)
        let project = { (c: Coordinate) in
            ((c.longitude - point.longitude) * metersPerDegree * cosLat, (c.latitude - point.latitude) * metersPerDegree)
        }
        var best = Double.infinity
        for (a, b) in zip(path, path.dropFirst()) {
            let (ax, ay) = project(a), (bx, by) = project(b)
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(ax * dx + ay * dy) / lengthSquared)) : 0
            let x = ax + t * dx, y = ay + t * dy
            best = min(best, (x * x + y * y).squareRoot())
        }
        return best
    }

    /// The running journey for a train number. A number can appear twice around midnight (yesterday's
    /// late run still underway), so the run that started on the leg's day wins, then the day before.
    /// Long-distance trains must match their category; regional ones only need to be regional too,
    /// since feeds disagree on RE vs. RB (bahn.jetzt lists the "RE 22" Eifel-Express as RB).
    static func match(category: String, number: Int, departure: Date, in journeys: [Journey]) -> Journey? {
        let longDistance = BahnDeClient.longDistanceCategories.contains(category.uppercased())
        let candidates = journeys.filter {
            guard $0.details?.transportAtStart?.journeyNumber == number,
                  let other = $0.details?.transportAtStart?.category?.uppercased() else { return false }
            return longDistance ? other == category.uppercased() : !BahnDeClient.longDistanceCategories.contains(other)
        }
        guard candidates.count > 1 else { return candidates.first }
        let days = [departure, departure.addingTimeInterval(-86_400)].map { BahnDeClient.berlinDay($0).replacing("-", with: "") }
        for day in days {
            if let journey = candidates.first(where: { $0.journeyId.hasPrefix(day) }) { return journey }
        }
        return candidates.first
    }

    /// Short enough that the 15 s position refresh always gets a fresh list, long enough that every
    /// leg of one refresh shares the same one.
    static let listMaxAge: TimeInterval = 10
    static let blockCooldown: TimeInterval = 5 * 60

    func snapshot() async throws -> Snapshot {
        try await state.snapshot(maxAge: Self.listMaxAge, cooldown: Self.blockCooldown) {
            var request = URLRequest(url: Self.baseURL.appending(path: "journeys"), timeoutInterval: self.http.timeout)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return Snapshot(journeys: try await self.http.send(request, as: [Journey].self), fetchedAt: .now)
        }
    }

    /// The last list fetched and whether bahn.jetzt is currently being left alone after a block.
    public actor State {
        public static let shared = State()

        private var last: Snapshot?
        private var inFlight: Task<Snapshot, Error>?
        private var blockedUntil: Date?

        public init() {}

        func snapshot(maxAge: TimeInterval, cooldown: TimeInterval,
                      fetch: @escaping @Sendable () async throws -> Snapshot) async throws -> Snapshot {
            if let last, Date.now.timeIntervalSince(last.fetchedAt) < maxAge { return last }
            if let blockedUntil, blockedUntil > .now { throw TransitError.rateLimited }
            if let inFlight { return try await inFlight.value }
            let task = Task { try await fetch() }
            inFlight = task
            defer { inFlight = nil }
            do {
                let snapshot = try await task.value
                last = snapshot
                return snapshot
            } catch let error as TransitError where error.isBlocked {
                blockedUntil = Date.now.addingTimeInterval(cooldown)
                throw TransitError.rateLimited
            }
        }
    }
}
