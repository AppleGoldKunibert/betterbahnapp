import CryptoKit
import Foundation
import Security

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String = PKCE.randomString(length: 64), state: String = PKCE.randomString(length: 24)) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
        self.state = state
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomString(length: Int) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct TraewellingConfig: Sendable {
    public var baseURL: URL
    /// BetterBahn's own public Träwelling OAuth client (no client secret, "confidential" off).
    public var clientID: String
    public var redirectURI: String
    public var scopes: [String]

    public init(baseURL: URL = URL(string: "https://traewelling.de")!, clientID: String = "406",
                redirectURI: String = "https://betterbahn.betterbahn.workers.dev/oauth/traewelling/callback",
                scopes: [String] = ["read-statuses", "write-statuses", "read-search", "write-likes", "read-notifications"]) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// Both components are nil unless the redirect is a valid HTTPS callback URL.
    public var callbackHost: String? { callbackComponents?.host }
    public var callbackPath: String? { callbackComponents?.percentEncodedPath }

    /// The HTTPS Worker forwards the OAuth response to this app-only scheme.
    /// Keep redirectURI unchanged in both OAuth requests; this is only the browser matcher.
    public var callbackScheme: String { "betterbahn" }

    private var callbackComponents: URLComponents? {
        guard let url = URL(string: redirectURI, encodingInvalidCharacters: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.percentEncodedPath.hasPrefix("/"),
              components.user == nil, components.password == nil,
              components.fragment == nil else { return nil }
        return components
    }

    /// `extra`: Träwelling's own additions to the login (e.g. a webhook, `FollowedCheckinPush.loginParameters`).
    public func authorizeURL(pkce: PKCE, extra: [URLQueryItem] = []) -> URL {
        baseURL.appending(path: "oauth/authorize").appending(queryItems: extra + [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: pkce.state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ])
    }

    /// The authorization code in the redirect URL from `ASWebAuthenticationSession`, once its state matches.
    public static func authorizationCode(in callbackURL: URL, pkce: PKCE) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == pkce.state else { throw OAuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw OAuthError.missingCode }
        return code
    }

    public var tokenURL: URL { baseURL.appending(path: "oauth/token") }
    public var apiURL: URL { baseURL.appending(path: "api/v1") }
}

public struct OAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

public enum OAuthError: Error, LocalizedError, Equatable {
    case stateMismatch
    case missingCode
    case notLoggedIn
    /// Träwelling no longer accepts the stored login (refresh token used up or expired).
    case sessionExpired
    /// Our server no longer has the login (logged out on another device, ended on traewelling.de).
    case loginEnded
    /// Our server, which keeps the login, doesn't answer and the last access token has run out.
    case serverUnavailable
    case invalidRedirectURI

    public var errorDescription: String? {
        switch self {
        case .stateMismatch: "Anmeldung abgebrochen (ungültiger Status)."
        case .missingCode: "Träwelling hat keinen Code zurückgegeben."
        case .notLoggedIn: "Nicht bei Träwelling angemeldet."
        case .sessionExpired: "Die Träwelling-Anmeldung ist abgelaufen. Melde dich in den Einstellungen ab und wieder an."
        case .loginEnded: "Deine Träwelling-Anmeldung ist beendet. Melde dich in den Einstellungen wieder an."
        case .serverUnavailable: "Träwelling geht gerade nicht, weil unser Server nicht antwortet. Versuch es gleich noch mal."
        case .invalidRedirectURI: "Ungültige Träwelling-OAuth-Konfiguration: Die Weiterleitungs-URL muss eine gültige HTTPS-Adresse mit Host und Callback-Pfad sein."
        }
    }
}

/// The Träwelling login in the Keychain: since #452 our server's login (`ServerLogin`, synced through iCloud
/// Keychain so the user's other devices use it too) and the access token last fetched for it (this device only).
/// Before #452 the app kept the token itself, also synced (`load()`, `save(_:)`); it is handed over to our
/// server once and then deleted.
public struct TokenStore: Sendable {
    let service: String
    let account: String

    public init(service: String = "de.betterbahn.traewelling", account: String = "oauth") {
        self.service = service
        self.account = account
    }

    private var loginAccount: String { "\(account).login" }
    private var accessAccount: String { "\(account).access" }
    private var pendingLogoutsAccount: String { "\(account).pendingLogouts" }

    /// Matches the item whether or not it syncs (older versions saved it device-only).
    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    private func read<Value: Decodable>(_ type: Value.Type, account: String) -> Value? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func write(_ value: some Encodable, account: String, synchronizable: Bool) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        SecItemDelete(baseQuery(account) as CFDictionary)
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        if SecItemAdd(query as CFDictionary, nil) != errSecSuccess, synchronizable {
            // No iCloud Keychain available (e.g. unsigned test runs): keep it on this device.
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    // MARK: Before #452

    /// The token the app kept itself before #452.
    public func load() -> OAuthToken? {
        read(OAuthToken.self, account: account)
    }

    public func save(_ token: OAuthToken) {
        write(token, account: account, synchronizable: true)
    }

    /// Re-saves a token older versions kept device-only so it syncs from now on.
    public func migrateToSynchronizable() {
        var query = baseQuery(account)
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess, let token = load() else { return }
        save(token)
    }

    /// Deletes the token from before #452, here and (synced) on the user's other devices.
    public func clearOwnToken() {
        delete(account: account)
    }

    // MARK: Our server's login (#452)

    public func loadLogin() -> ServerLogin? {
        read(ServerLogin.self, account: loginAccount)
    }

    public func saveLogin(_ login: ServerLogin) {
        write(login, account: loginAccount, synchronizable: true)
    }

    /// The access token last fetched for `loginID`, if this device has one.
    func loadAccess(for loginID: String) -> OAuthToken? {
        guard let stored = read(StoredAccess.self, account: accessAccount), stored.loginID == loginID else { return nil }
        return stored.token
    }

    func saveAccess(_ token: OAuthToken, for loginID: String) {
        write(StoredAccess(loginID: loginID, token: token), account: accessAccount, synchronizable: false)
    }

    /// Logins this device logged out of while our server couldn't be reached, to end there later.
    func loadPendingLogouts() -> [ServerLogin] {
        read([ServerLogin].self, account: pendingLogoutsAccount) ?? []
    }

    func savePendingLogouts(_ logins: [ServerLogin]) {
        if logins.isEmpty {
            delete(account: pendingLogoutsAccount)
        } else {
            write(logins, account: pendingLogoutsAccount, synchronizable: false)
        }
    }

    /// Deletes the login and its access token here and (synced) on the user's other devices, and the token
    /// from before #452.
    public func clearLogin() {
        delete(account: loginAccount)
        delete(account: accessAccount)
        delete(account: account)
    }

    /// Deletes everything, the logins still to end on our server too.
    public func clear() {
        clearLogin()
        delete(account: pendingLogoutsAccount)
    }

    private struct StoredAccess: Codable {
        var loginID: String
        var token: OAuthToken
    }
}
