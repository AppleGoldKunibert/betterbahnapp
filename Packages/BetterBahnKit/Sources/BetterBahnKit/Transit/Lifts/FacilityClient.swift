import Foundation

/// A station lift DB's FaSta API reports out of order (#486).
public struct BrokenLift: Codable, Sendable, Hashable, Identifiable {
    /// DB's equipment number.
    public var id: Int
    /// Where it goes, as DB writes it: "zu Gleis 4/5", "zur Unterführung".
    public var description: String
    public var coordinate: Coordinate?
    /// DB's reason, e.g. "under maintenance"; "not available" says nothing and counts as none.
    public var reason: String?

    public init(id: Int, description: String, coordinate: Coordinate?, reason: String? = nil) {
        self.id = id
        self.description = description
        self.coordinate = coordinate
        self.reason = reason
    }

    /// The reason in plain German, nil when DB gives none worth saying.
    public var reasonText: String? {
        switch reason?.lowercased() {
        case "under maintenance": "Wartung"
        case "under construction": "Bauarbeiten"
        default: nil
        }
    }
}

/// Every lift out of order at DB stations, from DB's FaSta (Facility Status) API through the
/// `Cloudflare/bahnde-proxy` Worker, which adds the API key and always asks for the whole list: the app
/// never says which station it looks at, and all users share the Worker's cached answer.
public struct FacilityClient: Sendable {
    public static let url = URL(string: "https://betterbahn2.betterbahn.workers.dev/fasta/v2/facilities")!
    /// The Worker keeps DB's answer this long, so asking more often gives nothing new.
    static let maxAge: TimeInterval = 5 * 60

    let http: HTTPClient
    let auth: WorkerAuth?

    /// `auth` defaults to `WorkerAuth.shared` on the app's real session and none on others (tests).
    public init(http: HTTPClient = HTTPClient(timeout: 8), auth: WorkerAuth? = nil) {
        self.http = http
        self.auth = http.workerAuth(auth)
    }

    private actor Cache {
        var lifts: (date: Date, value: [BrokenLift])?
        var inFlight: Task<[BrokenLift], Error>?

        func value(maxAge: TimeInterval, fetch: @escaping @Sendable () async throws -> [BrokenLift]) async throws -> [BrokenLift] {
            if let lifts, Date.now.timeIntervalSince(lifts.date) < maxAge { return lifts.value }
            if let inFlight { return try await inFlight.value }
            let task = Task { try await fetch() }
            inFlight = task
            defer { inFlight = nil }
            let value = try await task.value
            lifts = (.now, value)
            return value
        }
    }
    private static let cache = Cache()

    /// The lifts out of order now; nil when DB can't be asked (no network, no App Attest token).
    public func brokenLifts() async -> [BrokenLift]? {
        // Only the app's real session shares the cache, as in `TimetablesClient`.
        guard http.session === URLSession.shared else { return try? await fetch() }
        return try? await Self.cache.value(maxAge: Self.maxAge) { try await fetch() }
    }

    private func fetch() async throws -> [BrokenLift] {
        var request = URLRequest(url: Self.url, timeoutInterval: http.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try Self.parse(try await http.sendRaw(request, auth: auth))
    }

    /// FaSta's facilities; only lifts out of order, whatever else the answer holds. Throws when the answer
    /// isn't FaSta's list, so a changed format reads as "unknown" (and isn't cached), not as "all lifts work".
    static func parse(_ data: Data) throws -> [BrokenLift] {
        let facilities = try JSONDecoder().decode([Facility].self, from: data)
        return facilities.compactMap { facility in
            guard facility.type == "ELEVATOR", facility.state == "INACTIVE", let id = facility.equipmentnumber else { return nil }
            // FaSta's X is the longitude; 0/0 or nothing means DB doesn't know where it is.
            let coordinate = facility.geocoordY.flatMap { lat in
                facility.geocoordX.map { Coordinate(latitude: lat, longitude: $0) }
            }.flatMap { $0.latitude == 0 && $0.longitude == 0 ? nil : $0 }
            return BrokenLift(id: id, description: facility.description?.trimmingCharacters(in: .whitespaces) ?? "",
                              coordinate: coordinate, reason: facility.stateExplanation)
        }
    }

    private struct Facility: Decodable {
        var equipmentnumber: Int?
        var type: String?
        var description: String?
        var geocoordX: Double?
        var geocoordY: Double?
        var state: String?
        var stateExplanation: String?
    }
}
