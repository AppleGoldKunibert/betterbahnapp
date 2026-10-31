import Foundation

public enum TraewellingVisibility: Int, CaseIterable, Codable, Sendable {
    case publicVisible = 0, unlisted = 1, followers = 2, privateVisible = 3, authenticated = 4, trusted = 5

    public var label: String {
        switch self {
        case .publicVisible: String(kit: "Öffentlich")
        case .unlisted: String(kit: "Nicht gelistet")
        case .followers: String(kit: "Nur Follower")
        case .privateVisible: String(kit: "Privat")
        case .authenticated: String(kit: "Angemeldete Nutzer")
        case .trusted: String(kit: "Vertraute Nutzer")
        }
    }
}

public enum TraewellingBusiness: Int, CaseIterable, Codable, Sendable {
    case privateTrip = 0, business = 1, commute = 2

    public var label: String {
        switch self {
        case .privateTrip: String(kit: "Privat")
        case .business: String(kit: "Geschäftlich")
        case .commute: String(kit: "Pendeln")
        }
    }
}

public struct TraewellingUser: Decodable, Sendable {
    public var id: Int
    public var displayName: String
    public var username: String
    public var points: Int?
    /// Whether the user has Träwelling's points system switched on (off by default); without it
    /// check-ins earn 0 points, which the app then doesn't show.
    public var pointsEnabled: Bool?
    /// The connected Mastodon profile (e.g. "https://zug.network/@name"), whose instance's
    /// custom emojis the check-in text offers.
    public var mastodonUrl: String?
    /// Whether the user has likes on; Träwelling answers 403 to their likes otherwise.
    public var likesEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case id, displayName, username, points, pointsEnabled, mastodonUrl, likesEnabled = "likes_enabled"
    }
}

public struct TraewellingStation: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var latitude: Double?
    public var longitude: Double?
    /// DB EVA number, if Träwelling has one (sent as a number, tolerated as a string).
    public var ibnr: String?

    public init(id: Int, name: String, latitude: Double? = nil, longitude: Double? = nil, ibnr: String? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.ibnr = ibnr
    }

    private enum CodingKeys: String, CodingKey { case id, name, latitude, longitude, ibnr }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        if let number = try? container.decodeIfPresent(Int.self, forKey: .ibnr) {
            ibnr = String(number)
        } else {
            ibnr = try? container.decodeIfPresent(String.self, forKey: .ibnr)
        }
    }
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
    /// Checks in even though Träwelling has the user on another train at that time (`.collision`),
    /// e.g. when the previous train arrived early and Träwelling still has its scheduled arrival.
    /// Träwelling gives no points for such a check-in.
    public var force: Bool

    public init(leg: Leg, message: String = "", visibility: TraewellingVisibility = .publicVisible,
                business: TraewellingBusiness = .privateTrip, toot: Bool = false, force: Bool = false) {
        self.leg = leg
        self.message = message
        self.visibility = visibility
        self.business = business
        self.toot = toot
        self.force = force
    }
}

public struct StatusTag: Codable, Sendable, Hashable {
    public var key: String
    public var value: String
    public var visibility: TraewellingVisibility?

    public init(key: String, value: String, visibility: TraewellingVisibility?) {
        self.key = key
        self.value = value
        self.visibility = visibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decode(String.self, forKey: .value)
        // A visibility this app doesn't know must not hide the tag.
        visibility = try? container.decodeIfPresent(TraewellingVisibility.self, forKey: .visibility)
    }
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
    /// Liking was refused (403): the login predates the "write-likes" scope, or likes are off.
    case likeNotAllowed
    case api(status: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .stationNotFound(let name): String(kit: "Träwelling kennt den Bahnhof „%@“ nicht.", name)
        case .stopNotOnTrip(let name, let stops):
            String(kit: "„%@“ ist auf der Träwelling-Fahrt nicht enthalten. Halte dort: %@.", name, stops.joined(separator: ", "))
        case .tripNotFound(let line): String(kit: "%@ wurde auf Träwelling nicht gefunden.", line)
        case .collision: String(kit: "Du bist zu dieser Zeit schon eingecheckt.")
        case .likeNotAllowed:
            String(kit: "Träwelling lässt das Liken nicht zu. Melde dich in den Einstellungen einmal ab und wieder bei Träwelling an, damit BetterBahn Likes vergeben darf.")
        case .api(let status, let message): message ?? String(kit: "Träwelling-Fehler (%lld)", status)
        }
    }

    /// Träwelling rejected what was typed in (its validation answers 422, e.g. a text that's too long),
    /// so the form brings the keyboard back to fix it. Other errors leave it hidden.
    public var isInvalidInput: Bool {
        if case .api(422, _) = self { true } else { false }
    }
}

/// How long finding a train for a checkin may take before it gives up and offers a manual trip:
/// short when Träwelling answers quickly, longer on a slow connection, judged by how long its
/// station search took.
public struct TraewellingSearchBudget: Sendable {
    public var fast: Duration
    public var slow: Duration
    /// A station search taking longer than this counts as a slow connection.
    public var slowStationSearch: Duration

    public init(fast: Duration = .seconds(15), slow: Duration = .seconds(45), slowStationSearch: Duration = .seconds(3)) {
        self.fast = fast
        self.slow = slow
        self.slowStationSearch = slowStationSearch
    }

    /// The time for the whole search after a station search that took `stationSearch` (`nil`: unknown).
    func time(afterStationSearchTook stationSearch: Duration?) -> Duration {
        guard let stationSearch, stationSearch > slowStationSearch else { return fast }
        return slow
    }
}

public actor TraewellingClient {
    public nonisolated let config: TraewellingConfig
    let http: HTTPClient
    let store: TokenStore
    /// Keeps the login and renews it (#452); the app only fetches access tokens there.
    let loginServer: TraewellingLoginServer
    /// Autocomplete results per query and recent departures per station and time, so a checkin that
    /// tries again (under another train name, then as a manual trip) doesn't repeat every lookup (#106).
    private var stationCache: [String: [TraewellingStation]] = [:]
    private var departuresCache: [String: (fetched: Date, departures: [TraewellingDeparture])] = [:]
    let searchBudget: TraewellingSearchBudget
    /// How long the last station search that reached Träwelling took, to tell a slow connection.
    private var lastStationSearch: Duration?
    /// Asks the system for time to finish handing the login over and hands back what ends it again.
    public typealias KeepAlive = @Sendable () async -> @Sendable () async -> Void
    let keepAlive: KeepAlive?

    /// `keepAlive` keeps the app running while handing a login from before #452 over to our server waits
    /// for its answer (a background task in the app). `loginServer` defaults to our server, asked with `http`.
    public init(config: TraewellingConfig, http: HTTPClient = HTTPClient(timeout: 30), store: TokenStore = TokenStore(),
                loginServer: TraewellingLoginServer? = nil, searchBudget: TraewellingSearchBudget = TraewellingSearchBudget(),
                keepAlive: KeepAlive? = nil) {
        self.config = config
        self.http = http
        self.searchBudget = searchBudget
        self.keepAlive = keepAlive
        self.store = store
        self.loginServer = loginServer ?? TraewellingLoginServer(http: http)
        store.migrateToSynchronizable()
    }

    /// Re-reads the Keychain each time, since the login may have been added or removed on another device
    /// and synced in through iCloud Keychain.
    public var isLoggedIn: Bool {
        finishPendingLogouts()
        return store.loadLogin() != nil || store.load() != nil
    }

    /// Whether the login can read Träwelling's notifications (likes, fellow travellers). One handed over
    /// from before #452 can't until the user signs in again (`completeLogin`).
    public var readsNotifications: Bool {
        store.loadLogin()?.readsNotifications ?? false
    }

    // MARK: Auth

    /// Signs in with the redirect URL from `ASWebAuthenticationSession`: our server exchanges the code and
    /// keeps the login. Signing in while logged in replaces the login's tokens in place, so the
    /// notifications running on it carry on.
    public func completeLogin(callbackURL: URL, pkce: PKCE) async throws {
        let code = try TraewellingConfig.authorizationCode(in: callbackURL, pkce: pkce)
        if let login = store.loadLogin() {
            do {
                let (updated, token) = try await loginServer.signInAgain(login, code: code, codeVerifier: pkce.verifier)
                keep(updated, token)
                return
            } catch OAuthError.loginEnded {}
        }
        let (login, token) = try await loginServer.signIn(code: code, codeVerifier: pkce.verifier)
        keep(login, token)
    }

    /// The login at our server, after handing over a login from before #452 if there is one. Nil when
    /// logged out.
    public func serverLogin() async throws -> ServerLogin? {
        if let login = store.loadLogin() { return login }
        guard let refresh = store.load()?.refreshToken else { return nil }
        return try await handOver(refresh)
    }

    /// Fetches the next access token ahead when this one runs out within 10 minutes (or there is none),
    /// e.g. when the app is opened, so requests in a dead spot later still have one.
    public func prepareAccessToken() async {
        guard let login = try? await serverLogin() else { return }
        if let token = cachedAccess(for: login), token.expiresAt.timeIntervalSinceNow > Self.fetchAhead { return }
        _ = try? await startFetch(login).value
    }

    /// Logs out on this device and (through iCloud Keychain) the user's other ones, and ends the login at
    /// our server. Offline it is ended there on a later start.
    public func logout() async {
        let login = store.loadLogin()
        forgetLogin()
        guard let login else { return }
        do {
            try await loginServer.end(login)
        } catch {
            store.savePendingLogouts(store.loadPendingLogouts() + [login])
        }
    }

    private func forgetLogin() {
        access = nil
        store.clearLogin()
    }

    private func keep(_ login: ServerLogin, _ token: OAuthToken) {
        store.saveLogin(login)
        remember(token, for: login)
        // The token from before #452 has done its job.
        store.clearOwnToken()
    }

    private var endingLogouts: Task<Void, Never>?

    /// Ends the logins logged out of while our server couldn't be reached.
    private func finishPendingLogouts() {
        guard endingLogouts == nil, !store.loadPendingLogouts().isEmpty else { return }
        endingLogouts = Task {
            defer { endingLogouts = nil }
            var left: [ServerLogin] = []
            for login in store.loadPendingLogouts() {
                do {
                    try await loginServer.end(login)
                } catch {
                    left.append(login)
                }
            }
            store.savePendingLogouts(left)
        }
    }

    // MARK: Access token

    /// How long before the access token runs out the next one is fetched ahead.
    static let fetchAhead: TimeInterval = 10 * 60

    /// The access token last fetched, for the login it belongs to (also kept in the Keychain, this device only).
    private var access: (loginID: String, token: OAuthToken)?
    /// The fetch from our server in progress, if any.
    private var fetching: Task<OAuthToken, Error>?
    /// The handover of a login from before #452 in progress, if any.
    private var handingOver: Task<ServerLogin, Error>?
    /// The refresh token from before #452 Träwelling last rejected, so it isn't sent again on every request
    /// until the Keychain holds another one.
    private var rejectedRefreshToken: String?

    private func cachedAccess(for login: ServerLogin) -> OAuthToken? {
        if let access, access.loginID == login.id { return access.token }
        guard let token = store.loadAccess(for: login.id) else { return nil }
        access = (login.id, token)
        return token
    }

    private func remember(_ token: OAuthToken, for login: ServerLogin) {
        access = (login.id, token)
        store.saveAccess(token, for: login.id)
    }

    /// The access token to send: the one last fetched while it has time left (fetching the next one ahead in
    /// its last 10 minutes), else a new one from our server.
    private func validAccessToken() async throws -> String {
        let login: ServerLogin?
        do {
            login = try await serverLogin()
        } catch OAuthError.serverUnavailable {
            // Handing over has to wait for our server; the old token works while it lasts.
            if let own = store.load(), !own.isExpired { return own.accessToken }
            throw OAuthError.serverUnavailable
        }
        guard let login else {
            // A token from before #452 without a refresh token is used while it lasts.
            guard let own = store.load() else { throw OAuthError.notLoggedIn }
            return own.accessToken
        }
        if let token = cachedAccess(for: login), !token.isExpired {
            if token.expiresAt.timeIntervalSinceNow < Self.fetchAhead, fetching == nil { _ = startFetch(login) }
            return token.accessToken
        }
        return try await startFetch(login).value.accessToken
    }

    /// A new access token after Träwelling refused `rejected`: the one a fetch in progress brings, else one
    /// our server renews.
    private func newAccessToken(replacing rejected: String, for login: ServerLogin) async throws -> String {
        if let fetching, let token = try? await fetching.value, token.accessToken != rejected { return token.accessToken }
        if let token = cachedAccess(for: login), token.accessToken != rejected, !token.isExpired { return token.accessToken }
        return try await startFetch(login, rejected: rejected).value.accessToken
    }

    /// Fetching changes nothing at our server, so calls running together share one fetch only to save requests.
    private func startFetch(_ login: ServerLogin, rejected: String? = nil) -> Task<OAuthToken, Error> {
        if let fetching { return fetching }
        let task = Task {
            defer { fetching = nil }
            do {
                let (token, readsNotifications) = try await loginServer.token(for: login, rejected: rejected)
                // Logged out or in again meanwhile: the answer belongs to a login no longer kept.
                guard var current = store.loadLogin(), current.id == login.id else { throw OAuthError.notLoggedIn }
                remember(token, for: current)
                if current.readsNotifications != readsNotifications {
                    current.readsNotifications = readsNotifications
                    store.saveLogin(current)
                }
                return token
            } catch OAuthError.loginEnded {
                if store.loadLogin()?.id == login.id { forgetLogin() }
                throw OAuthError.loginEnded
            }
        }
        fetching = task
        return task
    }

    /// Hands a login from before #452 over to our server once (also when several calls ask together: the
    /// refresh token works once). Träwelling has renewed it before the answer arrives, so a handover cut off
    /// by iOS suspending the app would end the login: `keepAlive` asks for the time to finish it.
    private func handOver(_ refresh: String) async throws -> ServerLogin {
        if refresh == rejectedRefreshToken { throw OAuthError.sessionExpired }
        if let handingOver { return try await handingOver.value }
        let task = Task {
            defer { handingOver = nil }
            let endKeepAlive = await keepAlive?()
            do {
                let (login, token) = try await loginServer.handOver(refreshToken: refresh)
                await endKeepAlive?()
                // Another device handed it over meanwhile and its login synced in: that one is used, this one ended.
                if let synced = store.loadLogin() {
                    try? await loginServer.end(login)
                    return synced
                }
                store.saveLogin(login)
                remember(token, for: login)
                if store.load()?.refreshToken == refresh { store.clearOwnToken() }
                return login
            } catch OAuthError.sessionExpired {
                await endKeepAlive?()
                // Another device handed it over first; its login may sync in later. The old token stays:
                // deleting it would delete the synced Keychain item on every device.
                if let synced = store.loadLogin() { return synced }
                rejectedRefreshToken = refresh
                throw OAuthError.sessionExpired
            } catch {
                await endKeepAlive?()
                throw error
            }
        }
        handingOver = task
        return try await task.value
    }

    // MARK: API

    struct DataWrapper<T: Decodable & Sendable>: Decodable, Sendable { var data: T }

    private func api<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                                   body: Data? = nil, timeout: TimeInterval = 30, as type: T.Type) async throws -> T {
        let data = try await authorizedData(path, query: query, method: method, body: body, timeout: timeout)
        do {
            return try JSONDecoding.decoder.decode(T.self, from: data)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    /// Sends an authorized request and hands back the raw body, which is empty for a
    /// `204 No Content` reply (Träwelling uses one for "nothing is currently checked in").
    func authorizedData(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                        body: Data? = nil, timeout: TimeInterval = 30, isRetry: Bool = false) async throws -> Data {
        var url = config.apiURL.appending(path: path)
        if !query.isEmpty { url = url.appending(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let accessToken = try await validAccessToken()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(HTTPClient.identifyingUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            return try await http.sendRaw(request)
        } catch TransitError.http(let status, let responseBody) {
            if status == 401 {
                if !isRetry, let login = store.loadLogin() {
                    // Renewed meanwhile (by our server, for another device), or revoked: our server knows.
                    _ = try await newAccessToken(replacing: accessToken, for: login)
                    return try await authorizedData(path, query: query, method: method, body: body, timeout: timeout, isRetry: true)
                }
                if store.loadLogin() != nil { throw OAuthError.sessionExpired }
                // A token from before #452: another device may have stored a newer one meanwhile (it syncs via
                // iCloud Keychain); retry with that one instead of deleting it for every device.
                if !isRetry, let stored = store.load(), stored.accessToken != accessToken {
                    return try await authorizedData(path, query: query, method: method, body: body, timeout: timeout, isRetry: true)
                }
                forgetLogin()
                throw OAuthError.notLoggedIn
            }
            if status == 409 { throw TraewellingError.collision }
            throw TraewellingError.api(status: status, message: Self.message(from: responseBody))
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
        if let cached = stationCache[query] { return cached }
        let started = ContinuousClock.now
        let found = try await api("trains/station/autocomplete/\(query)", as: DataWrapper<[TraewellingStation]>.self).data
        lastStationSearch = ContinuousClock.now - started
        if stationCache.count > 200 { stationCache.removeAll() }
        stationCache[query] = found
        return found
    }

    /// `travelType` ("express", "regional", …, see `travelType(for:)`) leaves out every other kind of departure.
    public func departures(stationID: Int, when: Date, travelType: String? = nil, timeout: TimeInterval = 15) async throws -> [TraewellingDeparture] {
        let key = "\(stationID)|\(Int(when.timeIntervalSince1970))|\(travelType ?? "")"
        if let cached = departuresCache[key], cached.fetched.timeIntervalSinceNow > -120 { return cached.departures }
        var query: [URLQueryItem] = [.init(name: "when", value: JSONDecoding.isoString(when))]
        if let travelType { query.append(.init(name: "travelType", value: travelType)) }
        let found = try await api("station/\(stationID)/departures",
                                  query: query,
                                  timeout: timeout,
                                  as: DataWrapper<[TraewellingDeparture]>.self).data
        departuresCache = departuresCache.filter { $0.value.fetched.timeIntervalSinceNow > -120 }
        departuresCache[key] = (.now, found)
        return found
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
        guard let line = leg.line else { throw TraewellingError.tripNotFound(String(kit: "Fußweg")) }

        if let match = try await findDeparture(for: leg) {
            return try await checkin(draft, departures: match.departures)
        }
        guard allowManualTrip else { throw TraewellingError.tripNotFound(line.name) }
        return try await checkinManualTrip(draft)
    }

    /// Creates a manual trip and checks into it right away, for when a checkin just failed with
    /// `.tripNotFound`, so the search for the train doesn't run a second time.
    public func checkinAsManualTrip(_ draft: CheckinDraft) async throws -> CheckinResult {
        try await checkinManualTrip(draft)
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

    private func checkin(_ draft: CheckinDraft, departures: [TraewellingDeparture]) async throws -> CheckinResult {
        // Resolve every part first so a train Träwelling only half knows doesn't leave a stray
        // checkin for the first part behind.
        let segments = try await segments(for: draft.leg, departures: departures)
        var result: CheckinResult?
        for segment in segments {
            // The user's message/toot belong on the first part only, so a split train doesn't post
            // the same note twice.
            let segmentDraft = result == nil ? draft
                : CheckinDraft(leg: draft.leg, visibility: draft.visibility, business: draft.business, force: draft.force)
            let part = try await sendCheckin(segmentDraft, tripId: segment.tripId, lineName: segment.lineName,
                                             startID: segment.startID, destinationID: segment.destinationID,
                                             departure: segment.departure, arrival: segment.arrival)
            guard var combined = result else { result = part; continue }
            combined.points += part.points
            if let statusId = part.statusId { combined.connectingStatusIds.append(statusId) }
            result = combined
        }
        guard let result else { throw TraewellingError.tripNotFound(draft.leg.line?.name ?? String(kit: "Fußweg")) }
        return result
    }

    /// The Träwelling trips covering `leg`, from the first of `departures` whose trip has both ends of
    /// the leg. The board can list the same train twice at the same time (#449: ICE 1206 from
    /// Innsbruck once from Austrian data with only its main stops, once from German data with all
    /// of them), so a trip missing our stop doesn't end the checkin while another one may have it.
    private func segments(for leg: Leg, departures: [TraewellingDeparture], remainingSplits: Int = 3) async throws -> [Segment] {
        var firstError: Error?
        for departure in departures {
            do {
                return try await segments(for: leg, departure: departure, remainingSplits: remainingSplits)
            } catch let error as TraewellingError {
                guard case .stopNotOnTrip = error else { throw error }
                firstError = firstError ?? error
            }
        }
        throw firstError ?? TraewellingError.tripNotFound(leg.line?.name ?? String(kit: "Fußweg"))
    }

    /// The Träwelling trips covering `leg`, starting with `departure`'s. Usually just one, but
    /// through trains across a border (e.g. IC Zürich HB – Stuttgart Hbf) that our data has as a
    /// single run are split by Träwelling into one trip per network, the first of which ends at the
    /// border station. In that case this continues from wherever that trip ends with the next one.
    private func segments(for leg: Leg, departure: TraewellingDeparture, remainingSplits: Int = 3) async throws -> [Segment] {
        guard let line = leg.line else { throw TraewellingError.tripNotFound(String(kit: "Fußweg")) }
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
              let next = try await findDeparture(for: rest)?.departures.filter({ $0.tripId != departure.tripId }),
              !next.isEmpty else {
            throw TraewellingError.stopNotOnTrip(leg.destination.name, tripStops: trip.stopovers.map(\.name))
        }
        let first = Segment(tripId: departure.tripId, lineName: lineName, startID: origin.stationID,
                            destinationID: end.stationID, departure: departureTime,
                            arrival: end.arrivalPlanned ?? split.arrival?.planned ?? rest.departure.planned)
        return [first] + (try await segments(for: rest, departures: next, remainingSplits: remainingSplits - 1))
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
        let trip = try await createManualTrip(for: leg)
        var result = try await sendCheckin(draft, tripId: trip.tripId, lineName: trip.lineName,
                                           startID: trip.origin.id, destinationID: trip.destination.id,
                                           departure: leg.departure.planned, arrival: leg.arrival.planned)
        result.isManualTrip = true
        return result
    }

    private struct ManualTrip: Decodable, Sendable {
        struct StationRef: Decodable, Sendable { var id: Int }
        var tripId: String
        var lineName: String
        var origin: StationRef
        var destination: StationRef
    }

    /// Creates a Träwelling trip for `leg`'s train, running from its origin to its destination.
    private func createManualTrip(for leg: Leg) async throws -> ManualTrip {
        guard let line = leg.line else { throw TraewellingError.tripNotFound(String(kit: "Fußweg")) }
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
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await api("trips", method: "POST", body: data, as: DataWrapper<ManualTrip>.self).data
    }

    /// Turns a check-in into one on a manual trip covering `leg`, for an exit Träwelling's trip
    /// doesn't have (a stop added by hand, see `Stopover.manual(at:time:)`): `changeDestination`
    /// only accepts the trip's own stops, and a check-in can't be moved to another trip. So the old
    /// check-in is deleted and checked in again – only once the manual trip exists, so a failure
    /// before that leaves it untouched. Text, visibility, trip type and tags carry over; likes and
    /// comments can't. Not tooted again.
    public func replaceWithManualTrip(_ status: TraewellingStatus, leg: Leg) async throws -> CheckinResult {
        let draft = CheckinDraft(leg: leg, message: status.body ?? "",
                                 visibility: status.visibility ?? .publicVisible,
                                 business: status.business ?? .privateTrip)
        let trip = try await createManualTrip(for: leg)
        let tags = (try? await tags(statusId: status.id)) ?? status.tags
        try await deleteStatus(id: status.id)
        var result = try await sendCheckin(draft, tripId: trip.tripId, lineName: trip.lineName,
                                           startID: trip.origin.id, destinationID: trip.destination.id,
                                           departure: leg.departure.planned, arrival: leg.arrival.planned)
        result.isManualTrip = true
        if let statusId = result.statusId {
            // A tag that doesn't come along isn't worth failing the new check-in over.
            for tag in tags {
                _ = try? await addTag(statusId: statusId, key: tag.key, value: tag.value,
                                      visibility: tag.visibility ?? draft.visibility)
            }
        }
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
        guard let line = leg.line else { throw TraewellingError.tripNotFound(String(kit: "Fußweg")) }
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
        let hopResult = try await checkinManualTrip(CheckinDraft(leg: hopLeg, visibility: draft.visibility,
                                                                 business: draft.business, force: draft.force))

        var mainLeg = leg
        mainLeg.origin = nextStation
        mainLeg.departure = nextRegular.departure ?? arrival
        mainLeg.departurePlatform = nextRegular.departurePlatform
        var mainDraft = draft
        mainDraft.leg = mainLeg

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
        if draft.force { body["force"] = true }

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
        case .longDistance, .nightTrain, .interregio: "national"
        case .regionalExpress: "regionalExp"
        case .regional, .other: "regional"
        case .suburban: "suburban"
        case .subway: "subway"
        case .tram: "tram"
        case .bus, .coach: "bus"
        case .ferry: "ferry"
        }
    }

    /// Candidate Träwelling stations for `station`, best first (see `ranked(_:for:)`).
    private func candidateStations(for station: Station) async throws -> [(TraewellingStation, Double)] {
        // Keep querying until something plausible turns up: a query can return only far-away or
        // unrelated stations, in which case the simpler variants may still find the right one.
        var results: [TraewellingStation] = []
        var seen = Set<Int>()
        for query in Self.stationQueries(for: station.name) {
            for s in try await stations(matching: query) where seen.insert(s.id).inserted {
                results.append(s)
            }
            let ranked = Self.ranked(results, for: station)
            if station.coordinate == nil ? !results.isEmpty : ranked.contains(where: { $0.1 < 1_500 }) { break }
        }
        return Self.ranked(results, for: station)
    }

    /// Orders autocomplete results for `station` with their distance to it: the same EVA number first,
    /// then the same name close by (or anywhere without coordinates), then nearest first; stations
    /// without a coordinate keep API order at the end. Nearest alone isn't enough: at Hamburg Hbf the
    /// U-Bahn stop "Hauptbahnhof Süd" can be closer to our coordinate than Träwelling's Hbf, so a
    /// manual trip started at the subway stop.
    static func ranked(_ stations: [TraewellingStation], for station: Station) -> [(TraewellingStation, Double)] {
        let wanted = Set(stationQueries(for: station.name).map(Station.normalize))
        return stations.enumerated()
            .map { offset, s -> (tier: Int, offset: Int, station: TraewellingStation, distance: Double) in
                var distance = Double.infinity
                if let coordinate = station.coordinate, let lat = s.latitude, let lon = s.longitude {
                    distance = Coordinate(latitude: lat, longitude: lon).distance(to: coordinate)
                }
                let sameEva = station.evaNumber != nil && s.ibnr == station.evaNumber
                let sameName = wanted.contains(Station.normalize(s.name))
                    && (distance < 1_500 || station.coordinate == nil)
                return (sameEva ? 0 : sameName ? 1 : 2, offset, s, distance)
            }
            .sorted { ($0.tier, $0.distance, $0.offset) < ($1.tier, $1.distance, $1.offset) }
            .map { ($0.station, $0.distance) }
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
        guard let best = try await candidateStations(for: station).first else {
            throw TraewellingError.stationNotFound(station.name)
        }
        return best.0
    }

    /// Matches a departure to a HAFAS trip Träwelling knows about. Beyond the nearest station and a
    /// tight time window, this widens to nearby stations and a looser tolerance before giving up —
    /// Träwelling's own timetable data sometimes only has the train under a neighbouring stop or a
    /// fahrtNr/time that drifted a bit from our plan. All of it within `searchBudget`: then the boards
    /// still loading are given up on.
    private func findDeparture(for leg: Leg) async throws -> (station: TraewellingStation, departures: [TraewellingDeparture])? {
        guard leg.line != nil else { return nil }
        let started = ContinuousClock.now
        let candidates = try await candidateStations(for: leg.origin)
        let deadline = started + searchBudget.time(afterStationSearchTook: lastStationSearch)
        var answered = false
        var lastError: Error?
        var timedOut = false
        // Only the nearest few: in a big city the autocomplete has a dozen stations within 8 km, and
        // asking each of them one after the other kept the checkin loading for minutes (#106).
        for (maxDistance, tolerance, limit, alsoUnfiltered) in [(1_500.0, 2.0 * 60, 3, true), (8_000.0, 15.0 * 60, 4, false)] {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { timedOut = true; break }
            let stations = candidates.filter { $0.1 <= maxDistance }.prefix(limit).map(\.0)
            let when = leg.departure.planned.addingTimeInterval(-tolerance)
            let travelTypes = Self.boardTravelTypes(for: leg, alsoUnfiltered: alsoUnfiltered)
            let requests = stations.indices.flatMap { station in
                travelTypes.map { BoardRequest(station: station, travelType: $0) }
            }
            // No station that far: nothing to wait for.
            guard !requests.isEmpty else { continue }
            let timeout = max(1, Double(remaining.components.seconds))
            let (boards, deadlinePassed) = await withTaskGroup(of: BoardAnswer.self) { group in
                for (index, request) in requests.enumerated() {
                    let stationID = stations[request.station].id
                    group.addTask {
                        do {
                            let board = try await self.departures(stationID: stationID, when: when, travelType: request.travelType, timeout: timeout)
                            return .board(index, .success(board))
                        } catch {
                            return .board(index, .failure(error))
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    return .deadline
                }
                var boards = [Result<[TraewellingDeparture], any Error>?](repeating: nil, count: requests.count)
                var pending = requests.count
                var deadlinePassed = false
                for await answer in group {
                    guard case .board(let index, let board) = answer else { deadlinePassed = true; break }
                    boards[index] = board
                    pending -= 1
                    // Check in as soon as the best station that has the train is known, without
                    // waiting for the others.
                    if pending == 0 || Self.match(leg, on: boards, of: requests, at: stations, tolerance: tolerance, waitingForBetter: true) != nil {
                        break
                    }
                }
                group.cancelAll()
                return (boards, deadlinePassed)
            }
            for board in boards {
                switch board {
                case .success: answered = true
                case .failure(let error): lastError = error
                case nil: break
                }
            }
            if let match = Self.match(leg, on: boards, of: requests, at: stations, tolerance: tolerance, waitingForBetter: false) {
                return match
            }
            if deadlinePassed { timedOut = true; break }
        }
        // Not a single board loaded (offline, logged out, no answer in time): that's an error, not an unknown train.
        if !answered {
            if timedOut { throw TransitError.timeout }
            if let lastError { throw lastError }
        }
        return nil
    }

    private struct BoardRequest: Sendable {
        var station: Int
        var travelType: String?
    }

    private enum BoardAnswer: Sendable {
        case board(Int, Result<[TraewellingDeparture], any Error>)
        case deadline
    }

    /// The best station (first in `stations`, see `ranked(_:for:)`) whose boards have `leg`'s train,
    /// with every departure there that may be it, best first.
    /// A station whose boards are still loading is skipped, or with `waitingForBetter` ends the
    /// search, since it may yet have the train.
    private static func match(_ leg: Leg, on boards: [Result<[TraewellingDeparture], any Error>?], of requests: [BoardRequest],
                              at stations: [TraewellingStation], tolerance: TimeInterval,
                              waitingForBetter: Bool) -> (station: TraewellingStation, departures: [TraewellingDeparture])? {
        for (index, station) in stations.enumerated() {
            let stationBoards = zip(requests, boards).filter { $0.0.station == index }.map(\.1)
            if waitingForBetter, stationBoards.contains(where: { $0 == nil }) { return nil }
            let departures = stationBoards.flatMap { board -> [TraewellingDeparture] in
                if case .success(let departures)? = board { departures } else { [] }
            }
            let matches = Self.matches(departures, for: leg, tolerance: tolerance)
            if !matches.isEmpty { return (station, matches) }
        }
        return nil
    }

    /// The departure boards to load per station for `leg`, by Träwelling travel type (`nil`: all).
    /// Träwelling's board (MOTIS' stop times) lists the next 50 departures by their live time, bundled
    /// from every stop within 200 m, so at a busy interchange it spans only minutes (Berlin-Spandau with
    /// its bus stops: about ten) and a late train was past its end, so the checkin offered a manual
    /// trip (#289). Only the leg's kind of train spans hours there. The first, tight pass also loads
    /// the full board, in case Träwelling files the train under another kind.
    static func boardTravelTypes(for leg: Leg, alsoUnfiltered: Bool) -> [String?] {
        guard let travelType = leg.line.flatMap({ Self.travelType(for: $0.product) }) else { return [nil] }
        return alsoUnfiltered ? [nil, travelType] : [travelType]
    }

    /// Träwelling's travel type (departure filter) for a product.
    static func travelType(for product: Product) -> String? {
        switch product {
        case .highSpeed, .longDistance, .nightTrain, .interregio: "express"
        case .regionalExpress, .regional: "regional"
        case .suburban: "suburban"
        case .subway: "subway"
        case .tram: "tram"
        case .bus, .coach: "bus"
        case .ferry: "ferry"
        case .other: nil
        }
    }

    static func bestMatch(_ departures: [TraewellingDeparture], for leg: Leg, tolerance: TimeInterval) -> TraewellingDeparture? {
        matches(departures, for: leg, tolerance: tolerance).first
    }

    /// Every departure on the board that may be `leg`'s train, the closest to its planned time first
    /// (the board's own order on a tie), each trip once.
    static func matches(_ departures: [TraewellingDeparture], for leg: Leg, tolerance: TimeInterval) -> [TraewellingDeparture] {
        guard let line = leg.line else { return [] }
        let wantedName = Line.normalize(line.name)
        let candidates = departures.filter { dep in
            guard let planned = dep.plannedWhen,
                  abs(planned.timeIntervalSince(leg.departure.planned)) <= tolerance else { return false }
            if let name = dep.line.name, Line.normalize(name) == wantedName { return true }
            if let number = line.number {
                // Träwelling passes on MOTIS' trip short name as is: VBB's "03134" for our "RE2 (3134)".
                if let fahrtNr = dep.line.fahrtNr, !Self.trainNumber(fahrtNr).isEmpty,
                   Self.trainNumber(fahrtNr) == Self.trainNumber(number) { return true }
                // Cross-border trains are sometimes carried under a different product brand once they
                // switch networks (e.g. an ÖBB "RJ 177" is DB's "ICE 177" while still in Germany) — the
                // shared train number still identifies it even when the name/product prefix doesn't match.
                if let name = dep.line.name, Self.trailingNumber(name) == number { return true }
            }
            return false
        }
        var seen = Set<String>()
        return candidates.enumerated().sorted { a, b in
            let offsetA = abs((a.element.plannedWhen ?? .distantPast).timeIntervalSince(leg.departure.planned))
            let offsetB = abs((b.element.plannedWhen ?? .distantPast).timeIntervalSince(leg.departure.planned))
            return offsetA != offsetB ? offsetA < offsetB : a.offset < b.offset
        }
        .map(\.element)
        .filter { seen.insert($0.tripId).inserted }
    }

    /// A train number without leading zeros ("003135" → "3135").
    static func trainNumber(_ number: String) -> String {
        String(number.drop { $0 == "0" })
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
