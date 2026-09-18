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
                redirectURI: String = "https://betterbahn.kunibert88.workers.dev/oauth/traewelling/callback",
                scopes: [String] = ["read-statuses", "write-statuses", "read-search"]) {
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

    public func authorizeURL(pkce: PKCE) -> URL {
        baseURL.appending(path: "oauth/authorize").appending(queryItems: [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: pkce.state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ])
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

struct TokenResponse: Decodable {
    var access_token: String
    var refresh_token: String?
    var expires_in: Double?

    func toToken() -> OAuthToken {
        OAuthToken(accessToken: access_token, refreshToken: refresh_token,
                   expiresAt: Date.now.addingTimeInterval(expires_in ?? 3600 * 24 * 365))
    }
}

public enum OAuthError: Error, LocalizedError, Equatable {
    case stateMismatch
    case missingCode
    case notLoggedIn
    case invalidRedirectURI

    public var errorDescription: String? {
        switch self {
        case .stateMismatch: "Anmeldung abgebrochen (ungültiger Status)."
        case .missingCode: "Träwelling hat keinen Code zurückgegeben."
        case .notLoggedIn: "Nicht bei Träwelling angemeldet."
        case .invalidRedirectURI: "Ungültige Träwelling-OAuth-Konfiguration: Die Weiterleitungs-URL muss eine gültige HTTPS-Adresse mit Host und Callback-Pfad sein."
        }
    }
}

/// Stores the token in the Keychain.
public struct TokenStore: Sendable {
    let service: String
    let account: String

    public init(service: String = "de.betterbahn.traewelling", account: String = "oauth") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> OAuthToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    public func save(_ token: OAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
