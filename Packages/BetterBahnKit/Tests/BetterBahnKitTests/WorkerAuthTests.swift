import Foundation
import Testing
@testable import BetterBahnKit

/// `WorkerAuth` against a fake device and a fake Worker (`AuthWorkerProtocol`).
@Suite(.serialized) struct WorkerAuthTests {
    @Test func attestsOnceThenReusesKeyAndToken() async throws {
        let (auth, device, suite) = makeAuth()
        let defaults = UserDefaults(suiteName: suite)!
        let first = await auth.accessToken()
        let second = await auth.accessToken()

        #expect(first == "access-1")
        #expect(second == "access-1")
        #expect(device.counts == FakeAttest.Counts(keys: 1, attestations: 1, assertions: 1))
        #expect(AuthWorkerProtocol.state.paths == ["/auth/challenge", "/auth/attest", "/auth/challenge", "/auth/token"])
        #expect(defaults.string(forKey: WorkerAuth.keyIDDefaultsKey) == "key-1")
        #expect(defaults.string(forKey: WorkerAuth.keyTokenDefaultsKey) == "keytoken-for-key-1")

        // A new session (app relaunch) keeps the attested key: only an assertion is needed.
        let relaunched = WorkerAuth(attest: device, http: HTTPClient(session: AuthWorkerProtocol.session()),
                                    defaultsSuite: suite, baseURL: AuthWorkerProtocol.base)
        #expect(await relaunched.accessToken() == "access-2")
        #expect(device.counts == FakeAttest.Counts(keys: 1, attestations: 1, assertions: 2))
    }

    @Test func replacesARefusedKeyWithANewOne() async throws {
        let (auth, device, suite) = makeAuth()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("old-key", forKey: WorkerAuth.keyIDDefaultsKey)
        defaults.set("revoked", forKey: WorkerAuth.keyTokenDefaultsKey)

        #expect(await auth.accessToken() == "access-1")
        #expect(device.counts == FakeAttest.Counts(keys: 1, attestations: 1, assertions: 2))
        #expect(defaults.string(forKey: WorkerAuth.keyTokenDefaultsKey) == "keytoken-for-key-1")
    }

    @Test func retriesARefusedRequestOnceWithAFreshToken() async throws {
        let (auth, _, _) = makeAuth()
        let http = HTTPClient(session: AuthWorkerProtocol.session())
        AuthWorkerProtocol.state.acceptedTokens = ["access-2"]

        let data = try await http.sendRaw(URLRequest(url: AuthWorkerProtocol.base.appending(path: "data")), auth: auth)

        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(AuthWorkerProtocol.state.dataTokens == ["access-1", "access-2"])
    }

    @Test func sendsNothingWithoutAppAttest() async throws {
        let (auth, device, _) = makeAuth(supported: false)
        #expect(await auth.accessToken() == nil)
        #expect(device.counts == FakeAttest.Counts())
        #expect(AuthWorkerProtocol.state.paths.isEmpty)
    }

    @Test func clientsOnlyUseTheSharedAuthOnTheRealSession() {
        #expect(HTTPClient().workerAuth(nil) === WorkerAuth.shared)
        #expect(HTTPClient(session: AuthWorkerProtocol.session()).workerAuth(nil) == nil)
    }

    /// The auth, its fake device and the defaults suite it keeps the key in.
    private func makeAuth(supported: Bool = true) -> (WorkerAuth, FakeAttest, String) {
        AuthWorkerProtocol.state = .init()
        let suite = "WorkerAuthTests.\(UUID().uuidString)"
        let device = FakeAttest(isSupported: supported)
        let auth = WorkerAuth(attest: device, http: HTTPClient(session: AuthWorkerProtocol.session()),
                              defaultsSuite: suite, baseURL: AuthWorkerProtocol.base)
        return (auth, device, suite)
    }
}

final class FakeAttest: AppAttesting, @unchecked Sendable {
    struct Counts: Equatable { var keys = 0, attestations = 0, assertions = 0 }
    let isSupported: Bool
    private let lock = NSLock()
    private var _counts = Counts()
    var counts: Counts { lock.withLock { _counts } }

    init(isSupported: Bool) { self.isSupported = isSupported }

    func generateKey() async throws -> String {
        lock.withLock {
            _counts.keys += 1
            return "key-\(_counts.keys)"
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { _counts.attestations += 1 }
        return Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { _counts.assertions += 1 }
        return Data("assertion-\(keyID)".utf8)
    }
}

/// The Worker's `/auth` routes plus a `/data` route that wants a token from `acceptedTokens`.
final class AuthWorkerProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://auth.test/auth")!

    struct State {
        var paths: [String] = []
        var dataTokens: [String] = []
        var issued = 0
        /// Tokens `/data` accepts; empty means any.
        var acceptedTokens: Set<String> = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _state = State()
    static var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthWorkerProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        let body = Self.json(Self.body(of: request))
        var status = 200
        var response: String
        switch path {
        case "/auth/challenge":
            response = #"{"challenge":"challenge"}"#
        case "/auth/attest":
            let key = body["keyId"] ?? ""
            response = #"{"keyToken":"keytoken-for-\#(key)"}"#
        case "/auth/token":
            if body["keyToken"] == "revoked" {
                status = 401
                response = #"{"error":"invalid_key"}"#
            } else {
                let issued = Self.lock.withLock {
                    Self._state.issued += 1
                    return Self._state.issued
                }
                response = #"{"token":"access-\#(issued)","expiresIn":3600}"#
            }
        default:
            let token = request.value(forHTTPHeaderField: WorkerAuth.header) ?? ""
            let accepted = Self.lock.withLock {
                Self._state.dataTokens.append(token)
                return Self._state.acceptedTokens.isEmpty || Self._state.acceptedTokens.contains(token)
            }
            status = accepted ? 200 : 401
            response = accepted ? "ok" : #"{"error":"unauthorized"}"#
        }
        if path.hasPrefix("/auth/") { Self.lock.withLock { Self._state.paths.append(path) } }
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func json(_ data: Data) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
