import Foundation

/// Live train positions from DB's RIS::Maps through our Worker (`Cloudflare/positions`), which keeps the API key and
/// answers one shared list of every running train of DB Fernverkehr and DB Regio (cached 15 s there). Like
/// bahn.jetzt's list (which comes from RIS::Maps too), so the matching is `BahnJetztClient`'s; use it through
/// `TrainPositionClient`, which falls back to bahn.jetzt.
///
/// Only the genuine app gets an answer (App Attest token, `WorkerAuth`); without one (Simulator, app extensions)
/// nothing is sent.
public struct RISMapsClient: Sendable {
    public static let baseURL = URL(string: "https://betterbahn-positions.betterbahn.workers.dev")!
    public static let source = "RIS::Maps"
    /// The list is shared by every lookup of one refresh, as bahn.jetzt's.
    public static let sharedState = BahnJetztClient.State()

    let http: HTTPClient
    let auth: WorkerAuth?
    let state: BahnJetztClient.State
    let baseURL: URL

    /// `auth` defaults to `WorkerAuth.shared` on the app's real session and none on others (tests).
    public init(http: HTTPClient = HTTPClient(timeout: 8), auth: WorkerAuth? = nil,
                state: BahnJetztClient.State = RISMapsClient.sharedState, baseURL: URL = RISMapsClient.baseURL) {
        self.http = http
        self.auth = http.workerAuth(auth)
        self.state = state
        self.baseURL = baseURL
    }

    // MARK: Wire types (Cloudflare/positions/README.md)

    struct Answer: Decodable, Sendable {
        var fetchedAt: String?
        var trains: [Train]
    }

    struct Train: Decodable, Sendable {
        /// RIS' journey ID, e.g. "20261103-ba01d5ff-…"; starts with the day the run began.
        var id: String
        var category: String?
        /// The train number; for regional trains and S-Bahns the run number.
        var number: Int?
        /// e.g. "ICE 921", or the line ("RE51") for regional trains.
        var name: String?
        var line: String?
        var destination: String?
        var lat: Double
        var lon: Double
        var speed: Double?
        /// When the fix was taken (ISO 8601).
        var time: String?
        /// "SENSOR" (GPS on the train) or "SIGNALLING" (from the interlocking).
        var source: String?
    }

    /// The Worker's trains as the journeys `BahnJetztClient` matches.
    static func journeys(in answer: Answer) -> [BahnJetztClient.Journey] {
        answer.trains.map { train in
            BahnJetztClient.Journey(
                journeyId: train.id, position: [train.lon, train.lat], speed: train.speed, name: train.name ?? train.line,
                details: .init(transportAtStart: .init(category: train.category, journeyNumber: train.number,
                                                       journeyName: train.name ?? train.line),
                               destination: train.destination.map { .init(evaNumber: nil, name: $0) }),
                fixTime: train.time.flatMap(JSONDecoding.parseISODate))
        }
    }

    /// Every train RIS::Maps has a position for.
    /// - Throws: when the Worker can't be asked (no token) or doesn't answer; `TransitError.rateLimited` while it is
    ///   refusing requests.
    public func runningTrains() async throws -> [BahnJetztClient.RunningTrain] {
        BahnJetztClient.runningTrains(in: try await snapshot())
    }

    /// Live position of `line`'s run that departs (somewhere along its route) at `plannedDeparture`.
    /// - Returns: nil while the train isn't in the list.
    public func position(of line: Line?, plannedDeparture: Date, route: BahnJetztClient.RouteHint? = nil) async throws -> TrainPosition? {
        guard BahnJetztClient.reference(for: line) != nil else { return nil }
        return BahnJetztClient.position(of: line, plannedDeparture: plannedDeparture, route: route, in: try await snapshot())
    }

    func snapshot() async throws -> BahnJetztClient.Snapshot {
        // The Worker refuses requests without a token; don't send one that can only fail (tests' mocked sessions
        // have no Worker auth and answer anyway).
        if http.session === URLSession.shared, auth?.isSupported != true { throw TransitError.http(status: 401, body: nil) }
        return try await state.snapshot(maxAge: BahnJetztClient.listMaxAge, cooldown: BahnJetztClient.blockCooldown) {
            var request = URLRequest(url: self.baseURL.appending(path: "journeys"), timeoutInterval: self.http.timeout)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data = try await self.http.sendRaw(request, auth: auth)
            let answer: Answer
            do {
                answer = try JSONDecoder().decode(Answer.self, from: data)
            } catch {
                throw TransitError.decoding(String(describing: error))
            }
            return BahnJetztClient.Snapshot(journeys: Self.journeys(in: answer), fetchedAt: .now, source: Self.source)
        }
    }
}
