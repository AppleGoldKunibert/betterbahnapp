import Foundation

/// What the `betterbahn-live` Worker (`Cloudflare/live-activity`) needs to keep a journey's Live Activity
/// current while the app is closed (#315): its trains with their stops, times and platforms as the app
/// last saw them, and what DB's IRIS knows each train by (category, number, EVA numbers). The Worker
/// refreshes the times from IRIS and works out `TripActivityAttributes.ContentState.from(_:)` the same
/// way (`state.mjs`). No location, nothing about the user. Times are Unix seconds.
public struct LiveActivityPushJourney: Codable, Sendable, Equatable {
    public struct Time: Codable, Sendable, Equatable {
        public var planned: Int
        public var actual: Int?

        public init(_ time: TimeInfo) {
            planned = Self.seconds(time.planned)
            actual = time.actual.map(Self.seconds)
        }

        static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded()) }
    }

    public struct Platform: Codable, Sendable, Equatable {
        public var planned: String?
        public var actual: String?

        init?(_ platform: PlatformInfo?) {
            guard let platform, platform.planned != nil || platform.actual != nil else { return nil }
            planned = platform.planned
            actual = platform.actual
        }
    }

    /// A stop after the leg's start, up to its end: the next one gives the delay shown while riding.
    public struct Stop: Codable, Sendable, Equatable {
        public var eva: String?
        public var arrival: Time
    }

    public struct Leg: Codable, Sendable, Equatable {
        public var line: String
        /// How IRIS names the train ("ICE", "571"); nil when it can't be looked up there.
        public var category: String?
        public var number: String?
        public var product: Product
        public var night: Bool
        public var cancelled: Bool
        public var origin: String
        public var originEva: String?
        public var destination: String
        public var destinationEva: String?
        public var departure: Time
        public var arrival: Time
        public var departurePlatform: Platform?
        public var arrivalPlatform: Platform?
        public var stops: [Stop]
    }

    /// The journey's train legs (walks don't show in the Live Activity).
    public var legs: [Leg]

    /// `eva` finds a station's EVA number; the default needs no network (`evaNumber(for:)`).
    public init(_ journey: Journey, eva: (Station) -> String? = LiveActivityPushJourney.evaNumber(for:)) {
        legs = journey.transitLegs.map { leg in
            let line = leg.line
            let category = line.flatMap { TimetablesClient.category(from: $0.name) }
            let number = line?.dispatchNumber
            let lookup = category != nil && number != nil
            return Leg(line: line?.name ?? "Zug", category: lookup ? category : nil, number: lookup ? number : nil,
                       product: line?.product ?? .other, night: line?.isNightTrain ?? false, cancelled: leg.cancelled,
                       origin: leg.origin.displayName, originEva: eva(leg.origin),
                       destination: leg.destination.displayName, destinationEva: eva(leg.destination),
                       departure: Time(leg.departure), arrival: Time(leg.arrival),
                       departurePlatform: Platform(leg.departurePlatform), arrivalPlatform: Platform(leg.arrivalPlatform),
                       stops: leg.stopovers.dropFirst().compactMap { stop in
                           stop.arrival.map { Stop(eva: eva(stop.station), arrival: Time($0)) }
                       })
        }
    }

    /// The station's EVA number from the station itself or the offline list; for a station with several
    /// levels the main one, whose lower levels the Worker knows (as `TimetablesClient.lowerLevels`).
    public static func evaNumber(for station: Station) -> String? {
        station.evaNumber ?? StationNames.evaNumber(for: station) ?? StationNames.mainEvaNumber(for: station)
    }
}

/// A Live Activity's sign-up at the Worker. The app makes it up itself; only this device knows `secret`.
public struct LiveActivityPushRegistration: Codable, Sendable, Equatable {
    public var id: String
    public var secret: String
    /// The journey (`Journey.id`) whose activity it keeps current.
    public var journeyID: String

    public init(id: String, secret: String, journeyID: String) {
        self.id = id
        self.secret = secret
        self.journeyID = journeyID
    }

    /// A new sign-up with a random ID and secret.
    public init(journeyID: String) {
        self.init(id: Self.randomHex(bytes: 16), secret: Self.randomHex(bytes: 32), journeyID: journeyID)
    }

    private static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

/// Hands a running Live Activity to the Worker while the app is in the background, and takes it back.
///
/// iOS runs the app's background refresh when it likes, often much later than asked, so the activity
/// went stale while the app was closed. The Worker looks at the trains on `LiveActivityRefreshSchedule`'s
/// times instead and sends the new state with ActivityKit's push updates. While the app is open it
/// updates the activity itself, so it signs off again.
public struct LiveActivityPush: Sendable {
    public static let baseURL = URL(string: "https://betterbahn-live.betterbahn.workers.dev")!

    let http: HTTPClient
    let baseURL: URL

    public init(http: HTTPClient = HTTPClient(timeout: 15), baseURL: URL = LiveActivityPush.baseURL) {
        self.http = http
        self.baseURL = baseURL
    }

    /// Starts or replaces the sign-up with the activity's push token (`hex`) and the journey as it is now.
    /// `sandbox`: a development build, whose push tokens only work with APNs' sandbox.
    public func register(_ registration: LiveActivityPushRegistration, pushToken: String, sandbox: Bool,
                         journey: LiveActivityPushJourney) async throws {
        _ = try await send(registration, method: "PUT",
                           body: RegisterBody(secret: registration.secret, pushToken: pushToken, sandbox: sandbox, journey: journey))
    }

    /// Ends the sign-up. One the Worker no longer knows (the journey ended there) counts as ended.
    public func unregister(_ registration: LiveActivityPushRegistration) async throws {
        do {
            _ = try await send(registration, method: "DELETE", body: DeleteBody(secret: registration.secret))
        } catch TransitError.http(status: 404, _) {}
    }

    /// The activity's push token as the Worker takes it: lowercase hex.
    public static func hex(_ pushToken: Data) -> String {
        pushToken.map { String(format: "%02x", $0) }.joined()
    }

    private func send(_ registration: LiveActivityPushRegistration, method: String, body: some Encodable) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "activities/\(registration.id)"), timeoutInterval: http.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await http.sendRaw(request, auth: http.workerAuth(nil))
    }

    private struct RegisterBody: Encodable {
        var secret: String
        var pushToken: String
        var sandbox: Bool
        var journey: LiveActivityPushJourney
    }

    private struct DeleteBody: Encodable {
        var secret: String
    }
}
