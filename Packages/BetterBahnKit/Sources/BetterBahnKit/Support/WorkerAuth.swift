import CryptoKit
import DeviceCheck
import Foundation

/// The device side of App Attest (`DCAppAttestService`), behind a protocol so tests can fake it.
public protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

public struct DeviceAppAttest: AppAttesting {
    public init() {}

    public var isSupported: Bool { DCAppAttestService.shared.isSupported }

    public func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

/// Proves to BetterBahn's Cloudflare Workers (the bahn.de proxy with DB Timetables, the pass signer)
/// that a request comes from the genuine app on a real device, so nobody else can use them.
///
/// The device key is attested once (`/auth/attest` → a key token, kept in UserDefaults; it's useless
/// without the key in the Secure Enclave). After that an assertion gets a fresh access token every
/// hour (`/auth/token`), sent as `X-BetterBahn-Token`. The Worker side is
/// `Cloudflare/shared/appattest.mjs`. Without App Attest (Simulator, Mac) requests go out without a
/// token, which the Workers only accept while `ALLOW_UNATTESTED` is set.
public actor WorkerAuth {
    public static let shared = WorkerAuth()
    public static let baseURL = URL(string: "https://betterbahn2.betterbahn.workers.dev/auth")!
    public static let header = "X-BetterBahn-Token"
    /// After a failed attempt (no network, Apple's service down) the next one waits this long, so
    /// requests don't each start a new attestation.
    static let retryDelay: TimeInterval = 5 * 60
    static let keyIDDefaultsKey = "workerAuth.keyID"
    static let keyTokenDefaultsKey = "workerAuth.keyToken"

    private let attest: any AppAttesting
    private let http: HTTPClient
    private let defaults: UserDefaults
    private let baseURL: URL
    private var token: (value: String, expires: Date)?
    private var pending: Task<String?, Never>?
    private var failedAt: Date?

    /// `defaultsSuite` is where the attested key is remembered (the standard defaults when nil).
    public init(attest: any AppAttesting = DeviceAppAttest(), http: HTTPClient = HTTPClient(timeout: 15),
                defaultsSuite: String? = nil, baseURL: URL = WorkerAuth.baseURL) {
        self.attest = attest
        self.http = http
        self.defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.baseURL = baseURL
    }

    /// Whether this device can get tokens at all.
    public nonisolated var isSupported: Bool { attest.isSupported }

    /// A valid access token, or nil without App Attest or while the Worker can't be reached.
    public func accessToken() async -> String? {
        if let token, token.expires > Date.now.addingTimeInterval(60) { return token.value }
        if let pending { return await pending.value }
        if let failedAt, Date.now.timeIntervalSince(failedAt) < Self.retryDelay { return nil }
        let task = Task { await fetchToken() }
        pending = task
        let value = await task.value
        pending = nil
        failedAt = value == nil ? .now : nil
        return value
    }

    /// Forgets `value` after a Worker refused it, so the next call gets a fresh one.
    public func reject(_ value: String) {
        if token?.value == value { token = nil }
    }

    private func fetchToken() async -> String? {
        guard attest.isSupported else { return nil }
        for attempt in 0..<2 {
            do {
                let key = try await attestedKey()
                let challenge = try await challenge()
                let assertion = try await attest.generateAssertion(key.id, clientDataHash: Self.hash(challenge))
                let response = try await post("token", [
                    "keyToken": key.token, "assertion": assertion.base64EncodedString(), "challenge": challenge,
                ], as: TokenResponse.self)
                token = (response.token, Date.now.addingTimeInterval(response.expiresIn))
                return response.token
            } catch {
                // The key is unknown or refused (reinstalled app, restored backup, new server
                // secret): start over with a new key, once.
                guard attempt == 0, Self.needsNewKey(error) else { return nil }
                defaults.removeObject(forKey: Self.keyIDDefaultsKey)
                defaults.removeObject(forKey: Self.keyTokenDefaultsKey)
            }
        }
        return nil
    }

    private func attestedKey() async throws -> (id: String, token: String) {
        if let id = defaults.string(forKey: Self.keyIDDefaultsKey), let token = defaults.string(forKey: Self.keyTokenDefaultsKey) {
            return (id, token)
        }
        let id: String
        if let existing = defaults.string(forKey: Self.keyIDDefaultsKey) {
            id = existing
        } else {
            id = try await attest.generateKey()
            defaults.set(id, forKey: Self.keyIDDefaultsKey)
        }
        let challenge = try await challenge()
        let attestation = try await attest.attestKey(id, clientDataHash: Self.hash(challenge))
        let response = try await post("attest", [
            "keyId": id, "attestation": attestation.base64EncodedString(), "challenge": challenge,
        ], as: AttestResponse.self)
        defaults.set(response.keyToken, forKey: Self.keyTokenDefaultsKey)
        return (id, response.keyToken)
    }

    private nonisolated func challenge() async throws -> String {
        try await http.get(baseURL.appending(path: "challenge"), as: ChallengeResponse.self).challenge
    }

    private nonisolated func post<T: Decodable>(_ path: String, _ body: [String: String], as type: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: http.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return try await http.send(request, as: type)
    }

    static func hash(_ challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }

    static func needsNewKey(_ error: any Error) -> Bool {
        if let error = error as? DCError { return error.code == .invalidKey || error.code == .invalidInput }
        if case TransitError.http(let status, _) = error { return status == 401 || status == 403 }
        return false
    }

    struct ChallengeResponse: Decodable { var challenge: String }
    struct AttestResponse: Decodable { var keyToken: String }
    struct TokenResponse: Decodable { var token: String; var expiresIn: TimeInterval }
}

extension HTTPClient {
    /// `request` to one of BetterBahn's Workers, with an App Attest token when `auth` has one. A
    /// refused token (expired early, new server secret) is replaced once.
    func sendRaw(_ request: URLRequest, auth: WorkerAuth?) async throws -> Data {
        guard let auth, let token = await auth.accessToken() else { return try await sendRaw(request) }
        var request = request
        request.setValue(token, forHTTPHeaderField: WorkerAuth.header)
        do {
            return try await sendRaw(request)
        } catch TransitError.http(status: 401, let body) {
            await auth.reject(token)
            guard let fresh = await auth.accessToken(), fresh != token else { throw TransitError.http(status: 401, body: body) }
            request.setValue(fresh, forHTTPHeaderField: WorkerAuth.header)
            return try await sendRaw(request)
        }
    }

    /// The Worker auth a client on this session uses: the app's real session talks to the Workers
    /// with App Attest, tests' mocked sessions don't (unless they pass their own).
    func workerAuth(_ auth: WorkerAuth?) -> WorkerAuth? {
        auth ?? (session === URLSession.shared ? .shared : nil)
    }
}
