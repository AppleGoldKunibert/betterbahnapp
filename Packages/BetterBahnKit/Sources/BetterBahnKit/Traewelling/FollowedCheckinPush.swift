import Foundation

/// What the push Worker notifies about: new check-ins of the people the user follows (#266), likes on the
/// user's own check-ins and people checking in on the same train (#447).
public enum CheckinPushKind: String, Codable, Sendable, CaseIterable {
    case followed, likes, companions

    /// Likes and fellow travellers come from Träwelling's notifications, which the login can read only when
    /// it was made with `read-notifications` (`ServerLogin.readsNotifications`).
    public var readsNotifications: Bool { self != .followed }
}

/// A device's sign-up for those notifications at the `betterbahn-push` Worker (`Cloudflare/checkin-push`).
/// Only this device knows `secret`.
public struct FollowedCheckinPushSubscription: Codable, Sendable, Equatable {
    public var id: String
    public var secret: String
    /// Reads with the app's login at our server (#452). Sign-ups from before have a login of their own,
    /// which `syncFollowedCheckinPush` moves over.
    public var usesAppLogin: Bool

    public init(id: String, secret: String, usesAppLogin: Bool = true) {
        self.id = id
        self.secret = secret
        self.usesAppLogin = usesAppLogin
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        secret = try container.decode(String.self, forKey: .secret)
        usesAppLogin = try container.decodeIfPresent(Bool.self, forKey: .usesAppLogin) ?? false
    }
}

/// What turning a kind on or off needs at the Worker.
public enum CheckinPushStep: Equatable, Sendable {
    /// Signing in with Träwelling again first: the login can't read the notifications a kind needs.
    case signIn
    /// A new sign-up, with the app's login.
    case signUp
    /// The kinds of the existing sign-up change.
    case update
    /// Nothing is wanted any more (or nothing was signed up).
    case signOff
}

/// Signs the device up for those notifications, keeps its APNs device token and kinds current and signs it off.
///
/// iOS lets an app look in the background only when it likes, often hours later, so the Worker looks
/// instead, with the app's Träwelling login it keeps anyway (#452, `TraewellingLoginServer`).
public struct FollowedCheckinPush: Sendable {
    public static let baseURL = URL(string: "https://betterbahn-push.betterbahn.workers.dev")!

    let http: HTTPClient
    let baseURL: URL

    public init(http: HTTPClient = HTTPClient(timeout: 20), baseURL: URL = FollowedCheckinPush.baseURL) {
        self.http = http
        self.baseURL = baseURL
    }

    /// What to add to the app's Träwelling login (`TraewellingConfig.authorizeURL(pkce:extra:)`, kept by our
    /// server since #452): a webhook for the user's notifications while the Worker takes one, so likes and fellow
    /// travellers arrive right away. Nothing when the Worker can't be asked or doesn't take one yet (a login asking
    /// for a webhook Träwelling doesn't allow fails): the Worker's look every 2 minutes still finds them. Only
    /// Träwelling's own `trwl_` parameters, so nothing can replace the login's.
    public func loginParameters() async -> [URLQueryItem] {
        let request = URLRequest(url: baseURL.appending(path: "login-options"), timeoutInterval: http.timeout)
        guard let data = try? await http.sendRaw(request),
              let options = try? JSONDecoder().decode(LoginOptions.self, from: data) else { return [] }
        return options.authorize.filter { $0.key.hasPrefix("trwl_") }.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    /// What the Worker needs when the user wants `kinds`: signing in again when the login can't read the
    /// notifications a kind needs (`loginReadsNotifications`), a sign-up when there is none yet or one from
    /// before #452 with a login of its own.
    public static func step(for kinds: Set<CheckinPushKind>, subscription: FollowedCheckinPushSubscription?,
                            loginReadsNotifications: Bool) -> CheckinPushStep {
        guard !kinds.isEmpty else { return .signOff }
        if kinds.contains(where: \.readsNotifications), !loginReadsNotifications { return .signIn }
        guard let subscription, subscription.usesAppLogin else { return .signUp }
        return .update
    }

    /// Signs up with the app's login. `sandbox`: a development build, whose device token only works with
    /// APNs' sandbox. Throws `OAuthError.loginEnded` when the server no longer has the login.
    public func subscribe(login: ServerLogin, deviceToken: String, sandbox: Bool, userID: Int,
                          kinds: Set<CheckinPushKind>) async throws -> FollowedCheckinPushSubscription {
        let body = SubscribeBody(loginId: login.id, loginSecret: login.secret, deviceToken: deviceToken, sandbox: sandbox,
                                 userId: userID, kinds: Self.ordered(kinds))
        let data: Data
        do {
            data = try await send("subscriptions", method: "POST", body: body)
        } catch TransitError.http(status: 404, _) {
            throw OAuthError.loginEnded
        }
        do {
            var subscription = try JSONDecoder().decode(FollowedCheckinPushSubscription.self, from: data)
            subscription.usesAppLogin = true
            return subscription
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    /// Sends the current device token and kinds. False when the Worker no longer knows the subscription
    /// (Träwelling ended its login, or it was deleted): the notifications have stopped.
    public func update(_ subscription: FollowedCheckinPushSubscription, deviceToken: String, sandbox: Bool,
                       kinds: Set<CheckinPushKind>) async throws -> Bool {
        do {
            _ = try await send("subscriptions/\(subscription.id)", method: "PUT",
                               body: UpdateBody(secret: subscription.secret, deviceToken: deviceToken, sandbox: sandbox,
                                                kinds: Self.ordered(kinds)))
            return true
        } catch TransitError.http(status: 404, _) {
            return false
        }
    }

    /// Ends the subscription (and its own Träwelling login, before #452). One already gone counts as ended.
    public func unsubscribe(_ subscription: FollowedCheckinPushSubscription) async throws {
        do {
            _ = try await send("subscriptions/\(subscription.id)", method: "DELETE", body: DeleteBody(secret: subscription.secret))
        } catch TransitError.http(status: 404, _) {}
    }

    private static func ordered(_ kinds: Set<CheckinPushKind>) -> [CheckinPushKind] {
        CheckinPushKind.allCases.filter { kinds.contains($0) }
    }

    /// The APNs device token as the Worker takes it: lowercase hex.
    public static func hex(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    private func send(_ path: String, method: String, body: some Encodable) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: http.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await http.sendRaw(request, auth: http.workerAuth(nil))
    }

    private struct LoginOptions: Decodable {
        var authorize: [String: String]
    }

    private struct SubscribeBody: Encodable {
        var loginId: String
        var loginSecret: String
        var deviceToken: String
        var sandbox: Bool
        var userId: Int
        var kinds: [CheckinPushKind]
    }

    private struct UpdateBody: Encodable {
        var secret: String
        var deviceToken: String
        var sandbox: Bool
        var kinds: [CheckinPushKind]
    }

    private struct DeleteBody: Encodable {
        var secret: String
    }
}
