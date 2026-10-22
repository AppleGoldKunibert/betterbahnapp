import Foundation

/// This device at the push Worker for regular trips (#397, `Cloudflare/checkin-push`, `/commutes`). Made
/// on the device; the first update signs it up, and only this device knows `secret`.
public struct CommutePushRegistration: Codable, Sendable, Equatable {
    public var id: String
    public var secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }

    public static func make() -> CommutePushRegistration {
        func hex(_ bytes: Int) -> String {
            (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
        return CommutePushRegistration(id: hex(16), secret: hex(32))
    }
}

/// A saved journey of a regular trip's day the Worker looks after: its trains by DB category and number,
/// boarding and exit station by EVA number, with their planned times. Nothing else leaves the device.
public struct CommuteWatch: Codable, Sendable, Equatable {
    public var id: String
    public var threshold: Int
    public var legs: [Leg]

    public struct Leg: Codable, Sendable, Equatable {
        /// As shown in the notification, "RE 3".
        public var line: String
        /// What DB's own feed knows the train by: "RE", "3354".
        public var category: String
        public var number: String
        public var from: Stop
        public var to: Stop
    }

    public struct Stop: Codable, Sendable, Equatable {
        public var eva: String
        public var name: String
        /// Planned time, unix seconds.
        public var time: Int
    }

    /// The watch for `journey`, or nil when one of its trains can't be looked up in DB's feed (no number,
    /// a station without EVA number): the app then reports it itself while it runs.
    public static func make(journeyID: UUID, journey: Journey, threshold: Int,
                            eva: @Sendable (Station) async -> String?) async -> CommuteWatch? {
        var legs: [Leg] = []
        for leg in journey.transitLegs {
            guard let line = leg.line, let number = line.dispatchNumber,
                  let category = TimetablesClient.category(from: line.name),
                  let fromEVA = await eva(leg.origin), let toEVA = await eva(leg.destination) else { return nil }
            legs.append(Leg(line: line.displayName, category: category, number: number,
                            from: Stop(eva: fromEVA, name: leg.origin.displayName, time: Int(leg.departure.planned.timeIntervalSince1970)),
                            to: Stop(eva: toEVA, name: leg.destination.displayName, time: Int(leg.arrival.planned.timeIntervalSince1970))))
        }
        guard !legs.isEmpty else { return nil }
        return CommuteWatch(id: journeyID.uuidString, threshold: threshold, legs: legs)
    }
}

/// Hands the push Worker the journeys of regular trips this device has saved for today (#397), so delays,
/// cancellations, platform changes and transfers at risk arrive in time: iOS lets the app look in the
/// background only when it likes, often much later than a 7:42 train. The Worker asks DB's own timetable
/// feed (IRIS), never bahn.de.
public struct CommutePush: Sendable {
    /// The same Worker as the check-in notifications (#266, `FollowedCheckinPush`).
    public static let baseURL = URL(string: "https://betterbahn-push.betterbahn.workers.dev")!

    let http: HTTPClient
    let baseURL: URL

    public init(http: HTTPClient = HTTPClient(timeout: 20), baseURL: URL = CommutePush.baseURL) {
        self.http = http
        self.baseURL = baseURL
    }

    /// Replaces what the Worker looks after for this device (an empty list signs it off). Returns the IDs of
    /// the journeys it found every train of in DB's feed; the app reports the others itself.
    public func update(_ registration: CommutePushRegistration, deviceToken: String, sandbox: Bool,
                       watches: [CommuteWatch]) async throws -> Set<String> {
        var request = URLRequest(url: baseURL.appending(path: "commutes/\(registration.id)"), timeoutInterval: http.timeout)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(secret: registration.secret, deviceToken: deviceToken,
                                                         sandbox: sandbox, journeys: watches))
        let data = try await http.sendRaw(request, auth: http.workerAuth(nil))
        do {
            return Set(try JSONDecoder().decode(Answer.self, from: data).watched)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    /// The saved journey a notification from the Worker is about (tapping it opens that journey).
    public static let journeyIDKey = "commuteJourneyID"

    private struct Body: Encodable {
        var secret: String
        var deviceToken: String
        var sandbox: Bool
        var journeys: [CommuteWatch]
    }

    private struct Answer: Decodable {
        var watched: [String]
    }
}
