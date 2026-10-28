import Foundation
import Testing
@testable import BetterBahnKit

/// `FollowedCheckinPush` against a fake `betterbahn-push` Worker (`PushWorkerProtocol`, #266).
@Suite(.serialized) struct FollowedCheckinPushTests {
    private let push = FollowedCheckinPush(http: HTTPClient(session: PushWorkerProtocol.session()), baseURL: PushWorkerProtocol.base)
    private let subscription = FollowedCheckinPushSubscription(id: "sub1", secret: "s3cret")

    @Test func signsUpWithTheAuthorizationCode() async throws {
        PushWorkerProtocol.state = .init()
        let result = try await push.subscribe(code: "the-code", codeVerifier: "verifier", deviceToken: "abcd", sandbox: true, userID: 42,
                                              kinds: [.companions, .followed])
        #expect(result == FollowedCheckinPushSubscription(id: "new-id", secret: "new-secret", readsNotifications: true))
        let request = try #require(PushWorkerProtocol.state.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/subscriptions")
        #expect(request.body["code"] as? String == "the-code")
        #expect(request.body["codeVerifier"] as? String == "verifier")
        #expect(request.body["deviceToken"] as? String == "abcd")
        #expect(request.body["sandbox"] as? Bool == true)
        #expect(request.body["userId"] as? Int == 42)
        #expect(request.body["kinds"] as? [String] == ["followed", "companions"])
    }

    @Test func reportsASubscriptionTheWorkerNoLongerKnows() async throws {
        PushWorkerProtocol.state = .init()
        #expect(try await push.update(subscription, deviceToken: "abcd", sandbox: false, kinds: [.likes]))
        let request = try #require(PushWorkerProtocol.state.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/subscriptions/sub1")
        #expect(request.body["secret"] as? String == "s3cret")
        #expect(request.body["kinds"] as? [String] == ["likes"])

        PushWorkerProtocol.state = .init(status: 404)
        #expect(try await push.update(subscription, deviceToken: "abcd", sandbox: false, kinds: [.followed]) == false)
        PushWorkerProtocol.state = .init(status: 503)
        await #expect(throws: TransitError.self) { try await push.update(subscription, deviceToken: "abcd", sandbox: false, kinds: [.followed]) }
    }

    @Test func signsOffAndCountsAGoneSubscriptionAsEnded() async throws {
        PushWorkerProtocol.state = .init(status: 404)
        try await push.unsubscribe(subscription)
        #expect(PushWorkerProtocol.state.requests.first?.method == "DELETE")
    }

    @Test func asksTheWorkersLoginForReadingOnly() {
        let app = TraewellingConfig()
        let config = FollowedCheckinPush.config(from: app)
        #expect(config.scopes == ["read-statuses", "read-notifications"])
        #expect(config.clientID == app.clientID)
        #expect(config.redirectURI == app.redirectURI)
    }

    /// Likes and fellow travellers need a login that reads notifications (#447); one from before signs in again.
    @Test func signsInAgainOnlyWhenTheLoginCantReadWhatIsWanted() {
        let old = FollowedCheckinPushSubscription(id: "a", secret: "b")
        let new = FollowedCheckinPushSubscription(id: "a", secret: "b", readsNotifications: true)
        #expect(FollowedCheckinPush.step(for: [.followed], subscription: nil) == .signUp)
        #expect(FollowedCheckinPush.step(for: [.followed], subscription: old) == .update)
        #expect(FollowedCheckinPush.step(for: [.followed, .likes], subscription: old) == .signUp)
        #expect(FollowedCheckinPush.step(for: [.companions], subscription: new) == .update)
        #expect(FollowedCheckinPush.step(for: [], subscription: new) == .signOff)
        #expect(FollowedCheckinPush.step(for: [], subscription: nil) == .signOff)
    }

    /// Sign-ups saved before #447 have no `readsNotifications` yet.
    @Test func readsSignUpsSavedBeforeLikesAndFellowTravellers() throws {
        let saved = try JSONDecoder().decode(FollowedCheckinPushSubscription.self, from: Data(#"{"id":"a","secret":"b"}"#.utf8))
        #expect(saved == FollowedCheckinPushSubscription(id: "a", secret: "b", readsNotifications: false))
        let again = try JSONDecoder().decode(FollowedCheckinPushSubscription.self,
                                             from: JSONEncoder().encode(FollowedCheckinPushSubscription(id: "a", secret: "b", readsNotifications: true)))
        #expect(again.readsNotifications)
    }

    /// Träwelling's webhook for likes and fellow travellers (#447): only its own parameters, nothing when the Worker
    /// offers none or can't be reached.
    @Test func addsTheWebhookTheWorkerOffersToTheLogin() async throws {
        PushWorkerProtocol.state = .init(answer: Data(#"{"authorize":{"trwl_webhook_url":"https://w/hook","trwl_webhook_events":"notification","client_id":"evil"}}"#.utf8))
        let parameters = await push.loginParameters()
        #expect(parameters == [URLQueryItem(name: "trwl_webhook_events", value: "notification"),
                               URLQueryItem(name: "trwl_webhook_url", value: "https://w/hook")])
        #expect(PushWorkerProtocol.state.requests.first?.path == "/login-options")
        let url = TraewellingConfig().authorizeURL(pkce: PKCE(), extra: parameters)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "trwl_webhook_events", value: "notification")))
        #expect(items.filter { $0.name == "client_id" }.map(\.value) == ["406"])

        PushWorkerProtocol.state = .init(answer: Data(#"{"authorize":{}}"#.utf8))
        #expect(await push.loginParameters().isEmpty)
        PushWorkerProtocol.state = .init(status: 503)
        #expect(await push.loginParameters().isEmpty)
    }

    @Test func writesTheDeviceTokenAsLowercaseHex() {
        #expect(FollowedCheckinPush.hex(Data([0x0A, 0xFF, 0x00])) == "0aff00")
    }
}

final class PushWorkerProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://push.test")!

    struct Recorded: @unchecked Sendable {
        var method: String
        var path: String
        var body: [String: Any]
    }

    struct State: @unchecked Sendable {
        var status = 0
        var requests: [Recorded] = []
        /// Answer instead of the usual one.
        var answer: Data?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _state = State()
    static var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushWorkerProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        var status = Self.state.status
        Self.state.requests.append(Recorded(method: method, path: request.url?.path ?? "", body: body))
        if status == 0 { status = method == "POST" ? 201 : method == "DELETE" ? 204 : 200 }
        let answer = Self.state.answer ?? (status == 201 ? Data(#"{"id":"new-id","secret":"new-secret"}"#.utf8) : Data("{}".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
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
