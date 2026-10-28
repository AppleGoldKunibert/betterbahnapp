import Foundation

/// What the push Worker notifies about: new check-ins of the people the user follows (#266), likes on the
/// user's own check-ins and people checking in on the same train (#447).
public enum CheckinPushKind: String, Codable, Sendable, CaseIterable {
    case followed, likes, companions

    /// Likes and fellow travellers come from Träwelling's notifications, which the Worker's login can read
    /// only when it was made since #447.
    public var readsNotifications: Bool { self != .followed }
}

/// A device's sign-up for those notifications at the `betterbahn-push` Worker (`Cloudflare/checkin-push`).
/// Only this device knows `secret`.
public struct FollowedCheckinPushSubscription: Codable, Sendable, Equatable {
    public var id: String
    public var secret: String
    /// The Worker's login may read Träwelling's notifications (signed up since #447). Older sign-ups get
    /// only followed check-ins until the user signs in again.
    public var readsNotifications: Bool

    public init(id: String, secret: String, readsNotifications: Bool = false) {
        self.id = id
        self.secret = secret
        self.readsNotifications = readsNotifications
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        secret = try container.decode(String.self, forKey: .secret)
        readsNotifications = try container.decodeIfPresent(Bool.self, forKey: .readsNotifications) ?? false
    }
}

/// What turning a kind on or off needs at the Worker.
public enum CheckinPushStep: Equatable, Sendable {
    /// A new sign-up, with a new Träwelling login.
    case signUp
    /// The kinds of the existing sign-up change.
    case update
    /// Nothing is wanted any more (or nothing was signed up).
    case signOff
}

/// Signs the device up for those notifications, keeps its APNs device token and kinds current and signs it off.
///
/// iOS lets an app look in the background only when it likes, often hours later, so the Worker looks
/// instead. It needs its own Träwelling login (`config`: only reading): the app's access tokens
/// last an hour and each refresh token works once, so a login shared with the Worker would log one of
/// the two out. The app hands the Worker the authorization code with its PKCE verifier, and the Worker
/// exchanges it itself, so that login never exists on the device.
public struct FollowedCheckinPush: Sendable {
    public static let baseURL = URL(string: "https://betterbahn-push.betterbahn.workers.dev")!

    let http: HTTPClient
    let baseURL: URL

    public init(http: HTTPClient = HTTPClient(timeout: 20), baseURL: URL = FollowedCheckinPush.baseURL) {
        self.http = http
        self.baseURL = baseURL
    }

    /// The Träwelling login for the Worker: like the app's, but read-only.
    public static func config(from app: TraewellingConfig) -> TraewellingConfig {
        var config = app
        config.scopes = ["read-statuses", "read-notifications"]
        return config
    }

    /// What to add to the Worker's Träwelling login (`TraewellingConfig.authorizeURL(pkce:extra:)`): a webhook
    /// for the user's notifications while the Worker takes one, so likes and fellow travellers arrive right away.
    /// Nothing when the Worker can't be asked or doesn't take one yet (a login asking for a webhook Träwelling
    /// doesn't allow fails): the Worker's look every 2 minutes still finds them. Only Träwelling's own `trwl_`
    /// parameters, so nothing can replace the login's.
    public func loginParameters() async -> [URLQueryItem] {
        let request = URLRequest(url: baseURL.appending(path: "login-options"), timeoutInterval: http.timeout)
        guard let data = try? await http.sendRaw(request),
              let options = try? JSONDecoder().decode(LoginOptions.self, from: data) else { return [] }
        return options.authorize.filter { $0.key.hasPrefix("trwl_") }.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    /// What the Worker needs when the user wants `kinds`: a sign-up when there is none yet or its login
    /// can't read the notifications a kind needs.
    public static func step(for kinds: Set<CheckinPushKind>, subscription: FollowedCheckinPushSubscription?) -> CheckinPushStep {
        guard !kinds.isEmpty else { return .signOff }
        guard let subscription, subscription.readsNotifications || !kinds.contains(where: \.readsNotifications) else { return .signUp }
        return .update
    }

    /// `sandbox`: a development build, whose device token only works with APNs' sandbox.
    public func subscribe(code: String, codeVerifier: String, deviceToken: String, sandbox: Bool,
                          userID: Int, kinds: Set<CheckinPushKind>) async throws -> FollowedCheckinPushSubscription {
        let body = SubscribeBody(code: code, codeVerifier: codeVerifier, deviceToken: deviceToken, sandbox: sandbox, userId: userID,
                                 kinds: Self.ordered(kinds))
        let data = try await send("subscriptions", method: "POST", body: body)
        do {
            var subscription = try JSONDecoder().decode(FollowedCheckinPushSubscription.self, from: data)
            subscription.readsNotifications = true
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

    /// Ends the subscription and the Worker's Träwelling login. One already gone counts as ended.
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
        var code: String
        var codeVerifier: String
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
