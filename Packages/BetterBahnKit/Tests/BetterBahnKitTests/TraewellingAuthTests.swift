import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct TraewellingAuthTests {
    private let redirectURI = "https://betterbahn.kunibert88.workers.dev/oauth/traewelling/callback"

    @Test func defaultHTTPSCallback() {
        let config = TraewellingConfig(clientID: "public-client")
        #expect(config.redirectURI == redirectURI)
        #expect(config.callbackHost == "betterbahn.kunibert88.workers.dev")
        #expect(config.callbackPath == "/oauth/traewelling/callback")
        #expect(config.callbackScheme == "betterbahn")
    }

    @Test func callbackComponentsFollowRedirectURI() {
        var config = TraewellingConfig(clientID: "public-client")
        config.redirectURI = "https://example.com/another/callback"
        #expect(config.callbackHost == "example.com")
        #expect(config.callbackPath == "/another/callback")
    }

    @Test(arguments: ["", "not a URL", "http://example.com/callback", "example:/callback",
                      "https:///callback", "https://example.com", "https://exa mple.com/callback",
                      "https://example.com/call back", "https://user:password@example.com/callback",
                      "https://example.com/callback#fragment"])
    func invalidCallbacksAreRejected(_ redirectURI: String) {
        let config = TraewellingConfig(clientID: "public-client", redirectURI: redirectURI)
        #expect(config.callbackHost == nil)
        #expect(config.callbackPath == nil)
        #expect(OAuthError.invalidRedirectURI.localizedDescription.contains("HTTPS"))
    }

    @Test func authorizationRequestPreservesPKCEAndPublicClientParameters() throws {
        let config = TraewellingConfig(clientID: "public-client")
        let pkce = PKCE()
        let components = try #require(URLComponents(url: config.authorizeURL(pkce: pkce), resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(parameters == [
            "client_id": "public-client",
            "redirect_uri": redirectURI,
            "response_type": "code",
            "scope": "read-statuses write-statuses read-search",
            "state": pkce.state,
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
        ])
        #expect(parameters["client_secret"] == nil)
    }

    @Test func tokenExchangePreservesRedirectURIAndVerifier() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthTokenRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = TraewellingClient(
            config: TraewellingConfig(clientID: "public-client"),
            http: HTTPClient(session: session),
            store: TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        )
        let callback = try #require(URL(string: "betterbahn://oauth?code=test-code&state=test-state"))
        // The mock rejects the exchange after inspecting it, so no token is written to Keychain.
        await #expect(throws: TransitError.http(status: 400, body: "{}")) {
            try await client.completeLogin(callbackURL: callback, pkce: PKCE(verifier: "test-verifier", state: "test-state"))
        }
        await #expect(throws: OAuthError.stateMismatch) {
            try await client.completeLogin(callbackURL: callback, pkce: PKCE(state: "wrong-state"))
        }
    }
}

private final class OAuthTokenRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        #expect(request.url?.absoluteString == "https://traewelling.de/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(data: body, encoding: .utf8)
        let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(parameters == [
            "grant_type": "authorization_code",
            "client_id": "public-client",
            "redirect_uri": "https://betterbahn.kunibert88.workers.dev/oauth/traewelling/callback",
            "code_verifier": "test-verifier",
            "code": "test-code",
        ])
        #expect(parameters["client_secret"] == nil)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
