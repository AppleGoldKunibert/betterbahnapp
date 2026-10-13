import Foundation

/// A device's sign-up for notifications about new check-ins of the people the user follows (#266) at
/// the `betterbahn-push` Worker (`Cloudflare/checkin-push`). Only this device knows `secret`.
public struct FollowedCheckinPushSubscription: Codable, Sendable, Equatable {
    public var id: String
    public var secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }
}

/// Signs the device up for those notifications, keeps its APNs device token current and signs it off.
///
/// iOS lets an app look in the background only when it likes, often hours later, so the Worker looks
/// instead. It needs its own Träwelling login (`config`: only `read-statuses`): the app's access tokens
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
        config.scopes = ["read-statuses"]
        return config
    }

    /// `sandbox`: a development build, whose device token only works with APNs' sandbox.
    public func subscribe(code: String, codeVerifier: String, deviceToken: String, sandbox: Bool,
                          userID: Int) async throws -> FollowedCheckinPushSubscription {
        let body = SubscribeBody(code: code, codeVerifier: codeVerifier, deviceToken: deviceToken, sandbox: sandbox, userId: userID)
        let data = try await send("subscriptions", method: "POST", body: body)
        do {
            return try JSONDecoder().decode(FollowedCheckinPushSubscription.self, from: data)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    /// Sends the current device token. False when the Worker no longer knows the subscription (Träwelling
    /// ended its login, or it was deleted): the notifications have stopped.
    public func update(_ subscription: FollowedCheckinPushSubscription, deviceToken: String, sandbox: Bool) async throws -> Bool {
        do {
            _ = try await send("subscriptions/\(subscription.id)", method: "PUT",
                               body: UpdateBody(secret: subscription.secret, deviceToken: deviceToken, sandbox: sandbox))
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

    private struct SubscribeBody: Encodable {
        var code: String
        var codeVerifier: String
        var deviceToken: String
        var sandbox: Bool
        var userId: Int
    }

    private struct UpdateBody: Encodable {
        var secret: String
        var deviceToken: String
        var sandbox: Bool
    }

    private struct DeleteBody: Encodable {
        var secret: String
    }
}
