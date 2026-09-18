import Foundation

public enum TraewellingVisibility: Int, CaseIterable, Codable, Sendable {
    case publicVisible = 0, unlisted = 1, followers = 2, privateVisible = 3, authenticated = 4, trusted = 5

    public var label: String {
        switch self {
        case .publicVisible: "Öffentlich"
        case .unlisted: "Nicht gelistet"
        case .followers: "Nur Follower"
        case .privateVisible: "Privat"
        case .authenticated: "Angemeldete Nutzer"
        case .trusted: "Vertraute Nutzer"
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

public struct StatusTag: Codable, Sendable, Hashable {
    public var key: String
    public var value: String
    public var visibility: TraewellingVisibility?
}

public struct CheckinResult: Sendable {
    public var points: Int
    public var statusId: Int?
    public var alsoOnThisConnection: Int
    /// Whether Träwelling didn't know this train and a manual trip was created for it.
    public var isManualTrip = false
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
        // `api(_:)` builds the request URL with `URL.appending(path:)`, which percent-encodes
        // whatever it's given — pre-encoding here too would double-encode (e.g. "Berlin Hbf" →
        // "Berlin%20Hbf" → "Berlin%2520Hbf" on the wire), so the raw name is passed straight through.
        try await api("trains/station/autocomplete/\(query)", as: DataWrapper<[TraewellingStation]>.self).data
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

    /// Finds the matching Träwelling trip for a leg from our data sources and checks in. If Träwelling's
    /// own timetable doesn't know the train at all (common for trains the DB app shows but that are
    /// missing from Träwelling's HAFAS import), throws `.tripNotFound` unless `allowManualTrip` is set,
    /// in which case a manual trip is created and checked into instead.
    public func checkin(_ draft: CheckinDraft, allowManualTrip: Bool = false) async throws -> CheckinResult {
        let leg = draft.leg
        guard let line = leg.line else { throw TraewellingError.tripNotFound("Fußweg") }

        if let match = try await findDeparture(for: leg) {
            return try await checkin(draft, start: match.station, departure: match.departure)
        }
        guard allowManualTrip else { throw TraewellingError.tripNotFound(line.name) }
        return try await checkinManualTrip(draft)
    }

    private func checkin(_ draft: CheckinDraft, start: TraewellingStation, departure: TraewellingDeparture) async throws -> CheckinResult {
        let leg = draft.leg
        guard let line = leg.line else { throw TraewellingError.tripNotFound("Fußweg") }
        let lineName = departure.line.name ?? line.name
        let trip = try await trip(tripID: departure.tripId, lineName: lineName)
        // Träwelling's own timetable can list a station under a different internal ID than the one our
        // departure-board lookup found (e.g. a grouped "Hbf" ID vs. the specific ID this trip's own
        // stopovers reference) — sending an ID the trip itself doesn't recognize makes `trains/checkin`
        // fail with "Given stations are not on the trip". Resolve both ends against `trip.stopovers`,
        // the same source Träwelling validates against, instead of trusting the board lookup's ID.
        guard let origin = Self.matchStop(trip.stopovers, station: leg.origin,
                                          departure: departure.plannedWhen ?? leg.departure.planned) else {
            throw TraewellingError.stationNotFound(leg.origin.name)
        }
        guard let destination = Self.matchStop(trip.stopovers, station: leg.destination, arrival: leg.arrival.planned) else {
            throw TraewellingError.stationNotFound(leg.destination.name)
        }
        return try await sendCheckin(draft, tripId: departure.tripId, lineName: lineName,
                                     startID: origin.stationID, destinationID: destination.stationID,
                                     departure: origin.departurePlanned ?? departure.plannedWhen ?? leg.departure.planned,
                                     arrival: destination.arrivalPlanned ?? leg.arrival.planned)
    }

    /// Creates a Träwelling trip for a train its own timetable data doesn't have, then checks into it.
    private func checkinManualTrip(_ draft: CheckinDraft) async throws -> CheckinResult {
        let leg = draft.leg
        guard let line = leg.line else { throw TraewellingError.tripNotFound("Fußweg") }
        let origin = try await matchStation(leg.origin)
        let destination = try await matchStation(leg.destination)

        var body: [String: Any] = [
            "category": Self.hafasCategory(for: line.product),
            "lineName": line.name,
            "originId": origin.id,
            "originDeparturePlanned": JSONDecoding.isoString(leg.departure.planned),
            "destinationId": destination.id,
            "destinationArrivalPlanned": JSONDecoding.isoString(leg.arrival.planned),
        ]
        if let number = line.number, let journeyNumber = Int(number) { body["journeyNumber"] = journeyNumber }

        struct ManualTrip: Decodable, Sendable {
            struct StationRef: Decodable, Sendable { var id: Int }
            var tripId: String
            var lineName: String
            var origin: StationRef
            var destination: StationRef
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let trip = try await api("trips", method: "POST", body: data, as: DataWrapper<ManualTrip>.self).data

        var result = try await sendCheckin(draft, tripId: trip.tripId, lineName: trip.lineName,
                                           startID: trip.origin.id, destinationID: trip.destination.id,
                                           departure: leg.departure.planned, arrival: leg.arrival.planned)
        result.isManualTrip = true
        return result
    }

    /// Updates a manual trip's checked-in real times, used to reflect its live delay since
    /// Träwelling has no timetable of its own to track that for a manually created trip.
    @discardableResult
    public func updateCheckin(statusId: Int, departure: Date?, arrival: Date?) async throws -> TraewellingStatus {
        var body: [String: Any] = [:]
        if let departure { body["manual_departure"] = JSONDecoding.isoString(departure) }
        if let arrival { body["manual_arrival"] = JSONDecoding.isoString(arrival) }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await api("status/\(statusId)", method: "PUT", body: data, as: DataWrapper<TraewellingStatus>.self).data
    }

    /// Adds a key/value tag (e.g. `trwl:seat` = `"61"`) to a checked-in status.
    @discardableResult
    public func addTag(statusId: Int, key: String, value: String, visibility: TraewellingVisibility) async throws -> StatusTag {
        let body: [String: Any] = ["key": key, "value": value, "visibility": visibility.rawValue]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await api("status/\(statusId)/tags", method: "POST", body: data, as: DataWrapper<StatusTag>.self).data
    }

    private func sendCheckin(_ draft: CheckinDraft, tripId: String, lineName: String, startID: Int, destinationID: Int,
                              departure: Date, arrival: Date) async throws -> CheckinResult {
        var body: [String: Any] = [
            "tripId": tripId,
            "lineName": lineName,
            "start": startID,
            "destination": destinationID,
            "departure": JSONDecoding.isoString(departure),
            "arrival": JSONDecoding.isoString(arrival),
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

    /// Träwelling's manual-trip `category` field (`HafasTravelType`); there's no dedicated value for
    /// a long-distance coach or unclassified products, so those fall back to the closest rail category.
    static func hafasCategory(for product: Product) -> String {
        switch product {
        case .highSpeed: "nationalExpress"
        case .longDistance: "national"
        case .regionalExpress: "regionalExp"
        case .regional, .other: "regional"
        case .suburban: "suburban"
        case .subway: "subway"
        case .tram: "tram"
        case .bus, .coach: "bus"
        case .ferry: "ferry"
        }
    }

    /// Candidate Träwelling stations for `station`, nearest first (or API order if we have no coordinate).
    private func candidateStations(for station: Station) async throws -> [(TraewellingStation, Double)] {
        let results = try await stations(matching: station.name)
        guard let coordinate = station.coordinate else { return results.map { ($0, .infinity) } }
        return results
            .compactMap { s -> (TraewellingStation, Double)? in
                guard let lat = s.latitude, let lon = s.longitude else { return nil }
                return (s, Coordinate(latitude: lat, longitude: lon).distance(to: coordinate))
            }
            .sorted { $0.1 < $1.1 }
    }

    private func matchStation(_ station: Station) async throws -> TraewellingStation {
        let candidates = try await candidateStations(for: station)
        if let nearest = candidates.first, nearest.1 < 1_500 { return nearest.0 }
        guard let first = candidates.first else { throw TraewellingError.stationNotFound(station.name) }
        return first.0
    }

    /// Matches a departure to a HAFAS trip Träwelling knows about. Beyond the nearest station and a
    /// tight time window, this widens to nearby stations and a looser tolerance before giving up —
    /// Träwelling's own timetable data sometimes only has the train under a neighbouring stop or a
    /// fahrtNr/time that drifted a bit from our plan.
    private func findDeparture(for leg: Leg) async throws -> (station: TraewellingStation, departure: TraewellingDeparture)? {
        guard leg.line != nil else { return nil }
        let candidates = try await candidateStations(for: leg.origin)
        for (maxDistance, tolerance) in [(1_500.0, 2.0 * 60), (8_000.0, 15.0 * 60)] {
            for (station, distance) in candidates where distance <= maxDistance {
                let departures = try await departures(stationID: station.id, when: leg.departure.planned.addingTimeInterval(-tolerance))
                if let departure = Self.bestMatch(departures, for: leg, tolerance: tolerance) {
                    return (station, departure)
                }
            }
        }
        return nil
    }

    static func bestMatch(_ departures: [TraewellingDeparture], for leg: Leg, tolerance: TimeInterval) -> TraewellingDeparture? {
        guard let line = leg.line else { return nil }
        let wantedName = Line.normalize(line.name)
        let candidates = departures.filter { dep in
            guard let planned = dep.plannedWhen,
                  abs(planned.timeIntervalSince(leg.departure.planned)) <= tolerance else { return false }
            if let name = dep.line.name, Line.normalize(name) == wantedName { return true }
            if let number = line.number {
                if let fahrtNr = dep.line.fahrtNr, number == fahrtNr { return true }
                // Cross-border trains are sometimes carried under a different product brand once they
                // switch networks (e.g. an ÖBB "RJ 177" is DB's "ICE 177" while still in Germany) — the
                // shared train number still identifies it even when the name/product prefix doesn't match.
                if let name = dep.line.name, Self.trailingNumber(name) == number { return true }
            }
            return false
        }
        return candidates.min {
            abs(($0.plannedWhen ?? .distantPast).timeIntervalSince(leg.departure.planned))
                < abs(($1.plannedWhen ?? .distantPast).timeIntervalSince(leg.departure.planned))
        }
    }

    /// The run of digits at the end of a line name (e.g. "ICE 177" → "177"), used to match a train
    /// across networks that brand it under different names/products but keep the same number.
    static func trailingNumber(_ name: String) -> String? {
        let digits = name.reversed().prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits.reversed())
    }

    static func matchStop(_ stops: [TraewellingTrip.Stop], station: Station,
                          arrival: Date? = nil, departure: Date? = nil) -> TraewellingTrip.Stop? {
        if let arrival, let stop = stops.first(where: {
            guard let planned = $0.arrivalPlanned else { return false }
            return abs(planned.timeIntervalSince(arrival)) <= 2 * 60
        }) { return stop }
        if let departure, let stop = stops.first(where: {
            guard let planned = $0.departurePlanned else { return false }
            return abs(planned.timeIntervalSince(departure)) <= 2 * 60
        }) { return stop }
        return stops.first { Station.normalize($0.name) == Station.normalize(station.name) }
    }
}
