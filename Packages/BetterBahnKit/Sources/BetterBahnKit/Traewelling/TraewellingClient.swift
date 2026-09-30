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
    /// Set when boarding at a Zusatzhalt (unscheduled stop) required a short manual trip up to the
    /// next regular stop before checking in normally from there (see
    /// `checkin(_:fromZusatzhalt:toNextRegularStop:)`) — that hop's own status id and leg, tracked
    /// separately from `statusId` so its delay keeps updating like any other manual trip.
    public var zusatzhaltHop: (statusId: Int, leg: Leg)?
    /// Further statuses when Träwelling splits the train into several trips (e.g. at a border) and
    /// each part needed its own checkin; `statusId` is the first part.
    public var connectingStatusIds: [Int] = []
}

public enum TraewellingError: Error, LocalizedError, Equatable {
    case stationNotFound(String)
    /// The station was found on Träwelling, but none of the trip's stops matched it.
    case stopNotOnTrip(String, tripStops: [String])
    case tripNotFound(String)
    case collision
    case api(status: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .stationNotFound(let name): "Träwelling kennt den Bahnhof „\(name)“ nicht."
        case .stopNotOnTrip(let name, let stops):
            "„\(name)“ ist auf der Träwelling-Fahrt nicht enthalten. Halte dort: \(stops.joined(separator: ", "))."
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
        store.migrateToSynchronizable()
        self.token = store.load()
    }

    /// Re-reads the Keychain each time, since the token may have been added, refreshed or removed
    /// on another device and synced in through iCloud Keychain.
    public var isLoggedIn: Bool {
        token = store.load()
        return token != nil
    }

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
        token = store.load()
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
        let data = try await authorizedData(path, query: query, method: method, body: body)
        do {
            return try JSONDecoding.decoder.decode(T.self, from: data)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    /// Sends an authorized request and hands back the raw body, which is empty for a
    /// `204 No Content` reply (Träwelling uses one for "nothing is currently checked in").
    func authorizedData(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                        body: Data? = nil) async throws -> Data {
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
            return try await http.sendRaw(request)
        } catch TransitError.http(let status, let body) {
            if status == 401 { logout(); throw OAuthError.notLoggedIn }
            if status == 409 { throw TraewellingError.collision }
            throw TraewellingError.api(status: status, message: Self.message(from: body))
        }
    }

    /// Authorized request used by extensions.
    func authorized<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                                             body: Data? = nil, as type: T.Type) async throws -> T {
        try await api(path, query: query, method: method, body: body, as: type)
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
            return try await checkin(draft, departure: match.departure)
        }
        guard allowManualTrip else { throw TraewellingError.tripNotFound(line.name) }
        return try await checkinManualTrip(draft)
    }

    /// One Träwelling trip to check into, resolved before any checkin is sent.
    private struct Segment {
        var tripId: String
        var lineName: String
        var startID: Int
        var destinationID: Int
        var departure: Date
        var arrival: Date
    }

    private func checkin(_ draft: CheckinDraft, departure: TraewellingDeparture) async throws -> CheckinResult {
        // Resolve every part first so a train Träwelling only half knows doesn't leave a stray
        // checkin for the first part behind.
        let segments = try await segments(for: draft.leg, departure: departure)
        var result: CheckinResult?
        for segment in segments {
            // The user's message/toot belong on the first part only, so a split train doesn't post
            // the same note twice.
            let segmentDraft = result == nil ? draft
                : CheckinDraft(leg: draft.leg, visibility: draft.visibility, business: draft.business)
            let part = try await sendCheckin(segmentDraft, tripId: segment.tripId, lineName: segment.lineName,
                                             startID: segment.startID, destinationID: segment.destinationID,
                                             departure: segment.departure, arrival: segment.arrival)
            guard var combined = result else { result = part; continue }
            combined.points += part.points
            if let statusId = part.statusId { combined.connectingStatusIds.append(statusId) }
            result = combined
        }
        guard let result else { throw TraewellingError.tripNotFound(draft.leg.line?.name ?? "Fußweg") }
        return result
    }

    /// The Träwelling trips covering `leg`, starting with `departure`'s. Usually just one, but
    /// through trains across a border (e.g. IC Zürich HB – Stuttgart Hbf) that our data has as a
    /// single run are split by Träwelling into one trip per network, the first of which ends at the
    /// border station. In that case this continues from wherever that trip ends with the next one.
    private func segments(for leg: Leg, departure: TraewellingDeparture, remainingSplits: Int = 3) async throws -> [Segment] {
        guard let line = leg.line else { throw TraewellingError.tripNotFound("Fußweg") }
        let lineName = departure.line.name ?? line.name
        let trip = try await trip(tripID: departure.tripId, lineName: lineName)
        // Träwelling's own timetable can list a station under a different internal ID than the one our
        // departure-board lookup found (e.g. a grouped "Hbf" ID vs. the specific ID this trip's own
        // stopovers reference) — sending an ID the trip itself doesn't recognize makes `trains/checkin`
        // fail with "Given stations are not on the trip". Resolve both ends against `trip.stopovers`,
        // the same source Träwelling validates against, instead of trusting the board lookup's ID.
        let originDeparture = departure.plannedWhen ?? leg.departure.planned
        guard let origin = Self.matchStop(trip.stopovers, station: leg.origin, departure: originDeparture),
              let originIndex = trip.stopovers.firstIndex(where: {
                  $0.stationID == origin.stationID && $0.departurePlanned == origin.departurePlanned
              }) else {
            throw TraewellingError.stopNotOnTrip(leg.origin.name, tripStops: trip.stopovers.map(\.name))
        }
        let laterStops = Array(trip.stopovers[(originIndex + 1)...])
        let departureTime = origin.departurePlanned ?? originDeparture

        if let destination = Self.matchStop(laterStops, station: leg.destination, arrival: leg.arrival.planned) {
            return [Segment(tripId: departure.tripId, lineName: lineName, startID: origin.stationID,
                            destinationID: destination.stationID, departure: departureTime,
                            arrival: destination.arrivalPlanned ?? leg.arrival.planned)]
        }

        // Träwelling's trip ends before our destination: check in up to its last stop, then find the
        // train's continuation there.
        guard remainingSplits > 0, let end = laterStops.last,
              let split = Self.splitStopover(tripEnd: end, in: leg.stopovers),
              let rest = Self.remainder(of: leg, from: split),
              let next = try await findDeparture(for: rest)?.departure, next.tripId != departure.tripId else {
            throw TraewellingError.stopNotOnTrip(leg.destination.name, tripStops: trip.stopovers.map(\.name))
        }
        let first = Segment(tripId: departure.tripId, lineName: lineName, startID: origin.stationID,
                            destinationID: end.stationID, departure: departureTime,
                            arrival: end.arrivalPlanned ?? split.arrival?.planned ?? rest.departure.planned)
        return [first] + (try await segments(for: rest, departure: next, remainingSplits: remainingSplits - 1))
    }

    /// The intermediate stop of our leg where a Träwelling trip ending at `tripEnd` stops, if the
    /// leg carries on beyond it — i.e. where a through train Träwelling splits in two changes trips.
    static func splitStopover(tripEnd: TraewellingTrip.Stop, in stopovers: [Stopover]) -> Stopover? {
        guard stopovers.count > 2 else { return nil }
        let wanted = Set(stationQueries(for: tripEnd.name).map(Station.normalize))
        return stopovers.dropFirst().dropLast().first { stopover in
            guard stopover.departure != nil else { return false }
            if let planned = tripEnd.arrivalPlanned, let ours = stopover.arrival?.planned ?? stopover.departure?.planned,
               abs(planned.timeIntervalSince(ours)) > 5 * 60 {
                return false
            }
            if !wanted.isDisjoint(with: stationQueries(for: stopover.station.name).map(Station.normalize)) { return true }
            guard let coordinate = stopover.station.coordinate,
                  let lat = tripEnd.station?.latitude, let lon = tripEnd.station?.longitude else { return false }
            return Coordinate(latitude: lat, longitude: lon).distance(to: coordinate) < 1_500
        }
    }

    /// The rest of `leg` from `stopover` onwards, boarding there.
    static func remainder(of leg: Leg, from stopover: Stopover) -> Leg? {
        guard let index = leg.stopovers.firstIndex(of: stopover), let departure = stopover.departure else { return nil }
        var rest = leg
        rest.origin = stopover.station
        rest.departure = departure
        rest.departurePlatform = stopover.departurePlatform
        rest.stopovers = Array(leg.stopovers[index...])
        return rest
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

    /// Checks in a leg that boards at a Zusatzhalt (an unscheduled stop, e.g. after a diversion) which
    /// Träwelling's own timetable doesn't have — the reason the ordinary `checkin(_:allowManualTrip:)`
    /// above just failed with `.tripNotFound` even though Träwelling does know the train itself.
    /// Bridges the gap with a short manual trip from `zusatzhalt` up to `nextRegular` (the next stop
    /// that *is* part of the train's regular schedule, from `BahnDeClient.nextRegularStop`), then
    /// checks in normally from there to `draft.leg.destination`, since that part of the ride is
    /// exactly what Träwelling's timetable already has.
    public func checkin(_ draft: CheckinDraft, fromZusatzhalt zusatzhalt: JourneyStop, toNextRegularStop nextRegular: JourneyStop) async throws -> CheckinResult {
        let leg = draft.leg
        guard let line = leg.line else { throw TraewellingError.tripNotFound("Fußweg") }
        guard let departure = zusatzhalt.departure ?? zusatzhalt.arrival,
              let arrival = nextRegular.arrival ?? nextRegular.departure else {
            throw TraewellingError.tripNotFound(line.name)
        }
        // `leg.origin` already *is* the Zusatzhalt, with whatever real `Station` (coordinate included)
        // the app boarded the user at — no need to rebuild it from bahn.de's bare name. The next
        // regular stop isn't that lucky on its own (bahn.de's coordinate for it may be missing), but
        // Transitous' own stopovers for this leg do have it (unlike the Zusatzhalt, it's a stop
        // Transitous already knows) — looking it up there instead of a coordinate-less `Station` is
        // what lets the plain HAFAS-matched checkin below find it on Träwelling's departure board,
        // which needs a coordinate to trust a name match.
        let nextStation = Self.matchingStation(leg.stopovers, evaNumber: nextRegular.evaNumber, name: nextRegular.name)
            ?? Station(id: nextRegular.evaNumber, name: nextRegular.name, coordinate: nil, evaNumber: nextRegular.evaNumber, source: .bahnDe)

        var hopLeg = leg
        hopLeg.destination = nextStation
        hopLeg.departure = departure
        hopLeg.arrival = arrival
        hopLeg.departurePlatform = zusatzhalt.departurePlatform
        hopLeg.arrivalPlatform = nextRegular.arrivalPlatform
        hopLeg.stopovers = []
        // The user's message/toot belong on the main checkin below, not this short bridging hop, so
        // boarding at a Zusatzhalt doesn't post the same note to Träwelling twice.
        let hopResult = try await checkinManualTrip(CheckinDraft(leg: hopLeg, visibility: draft.visibility, business: draft.business))

        var mainLeg = leg
        mainLeg.origin = nextStation
        mainLeg.departure = nextRegular.departure ?? arrival
        mainLeg.departurePlatform = nextRegular.departurePlatform
        let mainDraft = CheckinDraft(leg: mainLeg, message: draft.message, visibility: draft.visibility, business: draft.business, toot: draft.toot)

        var result = try await checkin(mainDraft, allowManualTrip: false)
        result.points += hopResult.points
        if let hopStatusId = hopResult.statusId { result.zusatzhaltHop = (hopStatusId, hopLeg) }
        return result
    }

    private static func matchingStation(_ stopovers: [Stopover], evaNumber: String, name: String) -> Station? {
        if let byEva = stopovers.first(where: { $0.station.evaNumber == evaNumber })?.station { return byEva }
        let normalized = Station.normalize(name)
        return stopovers.first(where: { Station.normalize($0.station.name) == normalized })?.station
    }

    /// Updates a manual trip's checked-in real times, used to reflect its live delay since
    /// Träwelling has no timetable of its own to track that for a manually created trip.
    @discardableResult
    public func updateCheckin(statusId: Int, departure: Date?, arrival: Date?) async throws -> TraewellingStatus {
        var body: [String: Any] = [:]
        if let departure {
            let value = JSONDecoding.isoString(departure)
            body["manualDeparture"] = value
            body["manual_departure"] = value
        }
        if let arrival {
            let value = JSONDecoding.isoString(arrival)
            body["manualArrival"] = value
            body["manual_arrival"] = value
        }
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
        // Keep querying until something plausible turns up: a query can return only far-away or
        // unrelated stations, in which case the simpler variants may still find the right one.
        var results: [TraewellingStation] = []
        var seen = Set<Int>()
        var ranked: [(TraewellingStation, Double)] = []
        for query in Self.stationQueries(for: station.name) {
            for s in try await stations(matching: query) where seen.insert(s.id).inserted {
                results.append(s)
                var distance = Double.infinity
                if let coordinate = station.coordinate, let lat = s.latitude, let lon = s.longitude {
                    distance = Coordinate(latitude: lat, longitude: lon).distance(to: coordinate)
                }
                ranked.append((s, distance))
            }
            if station.coordinate == nil ? !results.isEmpty : ranked.contains(where: { $0.1 < 1_500 }) { break }
        }
        // Nearest first; stations without a coordinate keep API order at the end.
        return ranked.enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element)
    }

    /// Autocomplete queries to try for a station name, most specific first. Some sources append a
    /// stop type ("Friesack (Mark), Bahnhof") that Träwelling's name search doesn't know, so the
    /// name is retried without the comma suffix and without a trailing "Bahnhof"/"Bhf".
    static func stationQueries(for name: String) -> [String] {
        var queries = [name.trimmingCharacters(in: .whitespaces)]
        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !queries.contains(trimmed) { queries.append(trimmed) }
        }
        var base = queries[0]
        if let comma = base.firstIndex(of: ",") { base = String(base[..<comma]) }
        add(base)
        for suffix in [" Bahnhof", " Bhf"] where base.hasSuffix(suffix) {
            add(String(base.dropLast(suffix.count)))
        }
        // Drop a parenthetical like "(Mark)" before trying DB's short form, which would reorder it.
        if let open = base.firstIndex(of: "(") { add(String(base[..<open])) }
        add(Station.displayName(for: base))
        return queries
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
        // On a leg whose final stops are only a minute or two apart (common on S-Bahn runs),
        // more than one stop can fall inside the tolerance window — picking the *first* one
        // within it (rather than the closest) could return the stop before the actual exit.
        if let arrival {
            let candidates = stops.filter {
                guard let planned = $0.arrivalPlanned else { return false }
                return abs(planned.timeIntervalSince(arrival)) <= 2 * 60
            }
            if let closest = candidates.min(by: { abs($0.arrivalPlanned!.timeIntervalSince(arrival)) < abs($1.arrivalPlanned!.timeIntervalSince(arrival)) }) {
                return closest
            }
        }
        if let departure {
            let candidates = stops.filter {
                guard let planned = $0.departurePlanned else { return false }
                return abs(planned.timeIntervalSince(departure)) <= 2 * 60
            }
            if let closest = candidates.min(by: { abs($0.departurePlanned!.timeIntervalSince(departure)) < abs($1.departurePlanned!.timeIntervalSince(departure)) }) {
                return closest
            }
        }
        // Our source names can carry a suffix Träwelling's don't ("Friesack (Mark), Bahnhof" vs
        // "Friesack (Mark)"), so compare against the simplified variants too.
        let wanted = Set(stationQueries(for: station.name).map(Station.normalize))
        if let byName = stops.first(where: { wanted.contains(Station.normalize($0.name)) }) { return byName }
        // Last resort: the stop within 1.5 km of our coordinate.
        guard let coordinate = station.coordinate else { return nil }
        return stops
            .compactMap { stop -> (TraewellingTrip.Stop, Double)? in
                guard let lat = stop.station?.latitude, let lon = stop.station?.longitude else { return nil }
                return (stop, Coordinate(latitude: lat, longitude: lon).distance(to: coordinate))
            }
            .filter { $0.1 < 1_500 }
            .min { $0.1 < $1.1 }?.0
    }
}
