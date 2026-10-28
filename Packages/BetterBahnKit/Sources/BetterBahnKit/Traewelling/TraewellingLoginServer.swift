import Foundation

/// The app's Träwelling login as our server keeps it (#452): only the user's devices know `secret`, shared
/// through iCloud Keychain (`TokenStore`).
public struct ServerLogin: Codable, Sendable, Equatable {
    public var id: String
    public var secret: String
    /// Made with `read-notifications`, so the notifications about likes and fellow travellers work. A login
    /// handed over from before #452 can't read them until the user signs in again.
    public var readsNotifications: Bool

    public init(id: String, secret: String, readsNotifications: Bool) {
        self.id = id
        self.secret = secret
        self.readsNotifications = readsNotifications
    }
}

/// Talks to the server keeping the app's Träwelling login (`Cloudflare/checkin-push/logins.mjs`).
///
/// Träwelling's access tokens last an hour and each refresh token works once. A device renewing its own
/// login lost it when the answer to a renewal didn't arrive (poor reception), or after 30 days without
/// opening the app. The server is now the only one renewing it; the app only fetches the current access
/// token, which changes nothing there, so a lost answer costs nothing.
public struct TraewellingLoginServer: Sendable {
    public static let baseURL = FollowedCheckinPush.baseURL

    let http: HTTPClient
    let baseURL: URL

    public init(http: HTTPClient = HTTPClient(timeout: 20), baseURL: URL = TraewellingLoginServer.baseURL) {
        self.http = http
        self.baseURL = baseURL
    }

    /// A new login: the server exchanges the authorization code itself.
    public func signIn(code: String, codeVerifier: String) async throws -> (login: ServerLogin, token: OAuthToken) {
        let answer = try await send("logins", method: "POST", body: CodeBody(code: code, codeVerifier: codeVerifier), as: NewLogin.self)
        return (answer.login, answer.token)
    }

    /// Hands over the refresh token of a login from before #452; the server renews it at once. Throws
    /// `OAuthError.sessionExpired` when Träwelling no longer accepts it.
    public func handOver(refreshToken: String) async throws -> (login: ServerLogin, token: OAuthToken) {
        do {
            let answer = try await send("logins", method: "POST", body: RefreshBody(refreshToken: refreshToken), as: NewLogin.self)
            return (answer.login, answer.token)
        } catch TransitError.http(status: 400, _) {
            throw OAuthError.sessionExpired
        }
    }

    /// Signs in again in place (e.g. for `read-notifications`): `id` and `secret` stay the same.
    public func signInAgain(_ login: ServerLogin, code: String, codeVerifier: String) async throws -> (login: ServerLogin, token: OAuthToken) {
        let answer = try await send("logins/\(login.id)", method: "PUT",
                                    body: CodeBody(secret: login.secret, code: code, codeVerifier: codeVerifier), as: Token.self)
        var login = login
        login.readsNotifications = answer.readsNotifications
        return (login, answer.token)
    }

    /// The login's current access token. `rejected`: the one Träwelling just refused, renewed even if it
    /// should still work. Throws `OAuthError.loginEnded` when the server no longer has the login.
    public func token(for login: ServerLogin, rejected: String? = nil) async throws -> (token: OAuthToken, readsNotifications: Bool) {
        let answer = try await send("logins/\(login.id)/token", method: "POST",
                                    body: TokenBody(secret: login.secret, rejected: rejected), as: Token.self)
        return (answer.token, answer.readsNotifications)
    }

    /// Logs out: the server ends the Träwelling login and the notifications running on it. One already
    /// gone counts as ended.
    public func end(_ login: ServerLogin) async throws {
        do {
            _ = try await sendRaw("logins/\(login.id)", method: "DELETE", body: TokenBody(secret: login.secret))
        } catch OAuthError.loginEnded {}
    }

    private func send<T: Decodable>(_ path: String, method: String, body: some Encodable, as type: T.Type) async throws -> T {
        let data = try await sendRaw(path, method: method, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    /// 404: the login has ended. No answer, or a server error: `OAuthError.serverUnavailable`.
    private func sendRaw(_ path: String, method: String, body: some Encodable) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: http.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            return try await http.sendRaw(request, auth: http.workerAuth(nil))
        } catch TransitError.http(status: 404, _) {
            throw OAuthError.loginEnded
        } catch TransitError.http(let status, let answer) where (400..<500).contains(status) && status != 401 {
            throw TransitError.http(status: status, body: answer)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OAuthError.serverUnavailable
        }
    }

    private struct CodeBody: Encodable {
        var secret: String?
        var code: String
        var codeVerifier: String
    }

    private struct RefreshBody: Encodable {
        var refreshToken: String
    }

    private struct TokenBody: Encodable {
        var secret: String
        var rejected: String?
    }

    private struct Token: Decodable {
        var accessToken: String
        /// Unix seconds.
        var expiresAt: TimeInterval
        var readsNotifications: Bool

        var token: OAuthToken {
            OAuthToken(accessToken: accessToken, refreshToken: nil, expiresAt: Date(timeIntervalSince1970: expiresAt))
        }
    }

    private struct NewLogin: Decodable {
        var id: String
        var secret: String
        var accessToken: String
        var expiresAt: TimeInterval
        var readsNotifications: Bool

        var login: ServerLogin { ServerLogin(id: id, secret: secret, readsNotifications: readsNotifications) }
        var token: OAuthToken {
            OAuthToken(accessToken: accessToken, refreshToken: nil, expiresAt: Date(timeIntervalSince1970: expiresAt))
        }
    }
}
