import Foundation

public enum TraewellingVisibility: Int, CaseIterable, Codable, Sendable {
    case publicVisible = 0, unlisted = 1, followers = 2, privateVisible = 3, authenticated = 4

    public var label: String {
        switch self {
        case .publicVisible: "Öffentlich"
        case .unlisted: "Nicht gelistet"
        case .followers: "Nur Follower"
        case .privateVisible: "Privat"
        case .authenticated: "Nur angemeldete Nutzer"
        }
    }
}

public enum TraewellingBusiness: Int, CaseIterable, Codable, Sendable {
    case privateTrip = 0, business = 1, commute = 2

    public var label: String {
        switch self {
        case .privateTrip: "Privat"
        case .business: "Geschäftlich"
        case .commute: "Pendeln"
        }
    }
}

public struct TraewellingUser: Decodable, Sendable {
    public var id: Int
    public var displayName: String
    public var username: String
    public var points: Int?
}

public struct TraewellingStation: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var latitude: Double?
    public var longitude: Double?
}

public struct TraewellingDeparture: Decodable, Sendable {
    public struct LineInfo: Decodable, Sendable { public var name: String?; public var fahrtNr: String? }
    public var tripId: String
    public var plannedWhen: Date?
    public var when: Date?
    public var line: LineInfo
    public var direction: String?
    public var station: TraewellingStation?
}

public struct TraewellingTrip: Decodable, Sendable {
    public struct Stop: Decodable, Sendable {
        /// Träwelling station ID (`stopoverId` is the stopover itself).
        public var id: Int
        public var name: String
        public var station: TraewellingStation?
        public var arrivalPlanned: Date?
        public var departurePlanned: Date?

        public var stationID: Int { station?.id ?? id }
    }
    public var id: Int?
    public var lineName: String?
    public var stopovers: [Stop]
}

public struct CheckinDraft: Sendable, Hashable {
    public var leg: Leg
    public var message: String
    public var visibility: TraewellingVisibility
    public var business: TraewellingBusiness
    public var toot: Bool

    public init(leg: Leg, message: String = "", visibility: TraewellingVisibility = .publicVisible,
                business: TraewellingBusiness = .privateTrip, toot: Bool = false) {
        self.leg = leg
        self.message = message
        self.visibility = visibility
        self.business = business
        self.toot = toot
    }
}

public struct CheckinResult: Sendable {
    public var points: Int
    public var statusId: Int?
    public var alsoOnThisConnection: Int
}

public enum TraewellingError: Error, LocalizedError, Equatable {
    case stationNotFound(String)
    case tripNotFound(String)
    case collision
    case api(status: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .stationNotFound(let name): "Träwelling kennt den Bahnhof „\(name)“ nicht."
        case .tripNotFound(let line): "\(line) wurde auf Träwelling nicht gefunden."
        case .collision: "Du bist zu dieser Zeit schon eingecheckt."
        case .api(let status, let message): message ?? "Träwelling-Fehler (\(status))"
        }
    }
}

public actor TraewellingClient {
    public nonisolated let config: TraewellingConfig
    let http: HTTPClient
    let store: TokenStore
    private var token: OAuthToken?

    public init(config: TraewellingConfig, http: HTTPClient = HTTPClient(timeout: 30), store: TokenStore = TokenStore()) {
        self.config = config
        self.http = http
        self.store = store
        self.token = store.load()
    }

    public var isLoggedIn: Bool { token != nil }

    // MARK: Auth

    /// Exchanges the redirect URL from `ASWebAuthenticationSession` for a token.
    public func completeLogin(callbackURL: URL, pkce: PKCE) async throws {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == pkce.state else { throw OAuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw OAuthError.missingCode }
        try await requestToken([
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "code_verifier": pkce.verifier,
            "code": code,
        ])
    }

    public func logout() {
        token = nil
        store.clear()
    }

    private func requestToken(_ form: [String: String]) async throws {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPClient.identifyingUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        let response = try await http.send(request, as: TokenResponse.self)
        let newToken = response.toToken()
        token = newToken
        store.save(newToken)
    }

    private func validAccessToken() async throws -> String {
        guard let token else { throw OAuthError.notLoggedIn }
        if token.isExpired, let refresh = token.refreshToken {
            try await requestToken([
                "grant_type": "refresh_token",
                "client_id": config.clientID,
                "refresh_token": refresh,
                "scope": config.scopes.joined(separator: " "),
            ])
        }
        guard let access = self.token?.accessToken else { throw OAuthError.notLoggedIn }
        return access
    }

    // MARK: API

    struct DataWrapper<T: Decodable & Sendable>: Decodable, Sendable { var data: T }

    private func api<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                                   body: Data? = nil, as type: T.Type) async throws -> T {
        var url = config.apiURL.appending(path: path)
        if !query.isEmpty { url = url.appending(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        request.setValue(HTTPClient.identifyingUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            return try await http.send(request, as: type)
        } catch TransitError.http(let status, let body) {
            if status == 401 { logout(); throw OAuthError.notLoggedIn }
            if status == 409 { throw TraewellingError.collision }
            throw TraewellingError.api(status: status, message: Self.message(from: body))
        }
    }

    /// Authorized GET used by extensions.
    func authorized<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        try await api(path, query: query, as: type)
    }

    static func message(from body: String?) -> String? {
        guard let data = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["message"] as? String
    }

    public func currentUser() async throws -> TraewellingUser {
        try await api("auth/user", as: DataWrapper<TraewellingUser>.self).data
    }

    public func stations(matching query: String) async throws -> [TraewellingStation] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        return try await api("trains/station/autocomplete/\(encoded)", as: DataWrapper<[TraewellingStation]>.self).data
    }

    public func departures(stationID: Int, when: Date) async throws -> [TraewellingDeparture] {
        try await api("station/\(stationID)/departures",
                      query: [.init(name: "when", value: JSONDecoding.isoString(when))],
                      as: DataWrapper<[TraewellingDeparture]>.self).data
    }

    public func trip(tripID: String, lineName: String) async throws -> TraewellingTrip {
        try await api("trains/trip", query: [
            .init(name: "hafasTripId", value: tripID),
            .init(name: "lineName", value: lineName),
        ], as: DataWrapper<TraewellingTrip>.self).data
    }

    /// Finds the matching Träwelling trip for a leg from our data sources and checks in.
    public func checkin(_ draft: CheckinDraft) async throws -> CheckinResult {
        let leg = draft.leg
        guard let line = leg.line else { throw TraewellingError.tripNotFound("Fußweg") }

        let start = try await matchStation(leg.origin)
        let departures = try await departures(stationID: start.id, when: leg.departure.planned.addingTimeInterval(-5 * 60))
        guard let departure = Self.bestMatch(departures, for: leg) else {
            throw TraewellingError.tripNotFound(line.name)
        }
        let lineName = departure.line.name ?? line.name
        let trip = try await trip(tripID: departure.tripId, lineName: lineName)
        guard let destination = Self.matchStop(trip.stopovers, station: leg.destination, arrival: leg.arrival.planned) else {
            throw TraewellingError.stationNotFound(leg.destination.name)
        }

        var body: [String: Any] = [
            "tripId": departure.tripId,
            "lineName": lineName,
            "start": start.id,
            "destination": destination.stationID,
            "departure": JSONDecoding.isoString(departure.plannedWhen ?? leg.departure.planned),
            "arrival": JSONDecoding.isoString(destination.arrivalPlanned ?? leg.arrival.planned),
            "visibility": draft.visibility.rawValue,
            "business": draft.business.rawValue,
            "toot": draft.toot,
        ]
        if !draft.message.isEmpty { body["body"] = String(draft.message.prefix(280)) }

        struct Response: Decodable, Sendable {
            struct Status: Decodable, Sendable { var id: Int? }
            struct Points: Decodable, Sendable { var points: Int }
            var status: Status?
            var points: Points
            var alsoOnThisConnection: [Status]?
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await api("trains/checkin", method: "POST", body: data, as: DataWrapper<Response>.self).data
        return CheckinResult(points: response.points.points, statusId: response.status?.id,
                             alsoOnThisConnection: response.alsoOnThisConnection?.count ?? 0)
    }

    private func matchStation(_ station: Station) async throws -> TraewellingStation {
        let results = try await stations(matching: station.name)
        if let coordinate = station.coordinate {
            let nearest = results
                .compactMap { s -> (TraewellingStation, Double)? in
                    guard let lat = s.latitude, let lon = s.longitude else { return nil }
                    return (s, Coordinate(latitude: lat, longitude: lon).distance(to: coordinate))
                }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 < 1_500 { return nearest.0 }
        }
        guard let first = results.first else { throw TraewellingError.stationNotFound(station.name) }
        return first
    }

    static func bestMatch(_ departures: [TraewellingDeparture], for leg: Leg) -> TraewellingDeparture? {
        guard let line = leg.line else { return nil }
        let wantedName = Line.normalize(line.name)
        let candidates = departures.filter { dep in
            guard let planned = dep.plannedWhen,
                  abs(planned.timeIntervalSince(leg.departure.planned)) <= 2 * 60 else { return false }
            if let name = dep.line.name, Line.normalize(name) == wantedName { return true }
            if let number = line.number, let fahrtNr = dep.line.fahrtNr, number == fahrtNr { return true }
            return false
        }
        return candidates.min {
            abs(($0.plannedWhen ?? .distantPast).timeIntervalSince(leg.departure.planned))
                < abs(($1.plannedWhen ?? .distantPast).timeIntervalSince(leg.departure.planned))
        }
    }

    static func matchStop(_ stops: [TraewellingTrip.Stop], station: Station, arrival: Date) -> TraewellingTrip.Stop? {
        stops.first {
            guard let planned = $0.arrivalPlanned else { return false }
            return abs(planned.timeIntervalSince(arrival)) <= 2 * 60
        } ?? stops.first { Station.normalize($0.name) == Station.normalize(station.name) }
    }
}
