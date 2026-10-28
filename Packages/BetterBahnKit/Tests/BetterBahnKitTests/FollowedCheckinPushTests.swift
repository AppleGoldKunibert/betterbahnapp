import Foundation
import Testing
@testable import BetterBahnKit

/// `FollowedCheckinPush` against a fake `betterbahn-push` Worker (`PushWorkerProtocol`, #266).
@Suite(.serialized) struct FollowedCheckinPushTests {
    private let push = FollowedCheckinPush(http: HTTPClient(session: PushWorkerProtocol.session()), baseURL: PushWorkerProtocol.base)
    private let subscription = FollowedCheckinPushSubscription(id: "sub1", secret: "s3cret")

    /// #452: no second Träwelling login, the Worker reads with the app's.
    @Test func signsUpWithTheAppsLogin() async throws {
        PushWorkerProtocol.state = .init()
        let login = ServerLogin(id: "login1", secret: "login-secret", readsNotifications: true)
        let result = try await push.subscribe(login: login, deviceToken: "abcd", sandbox: true, userID: 42, kinds: [.companions, .followed])
        #expect(result == FollowedCheckinPushSubscription(id: "new-id", secret: "new-secret", usesAppLogin: true))
        let request = try #require(PushWorkerProtocol.state.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/subscriptions")
        #expect(request.body["loginId"] as? String == "login1")
        #expect(request.body["loginSecret"] as? String == "login-secret")
        #expect(request.body["code"] == nil)
        #expect(request.body["deviceToken"] as? String == "abcd")
        #expect(request.body["sandbox"] as? Bool == true)
        #expect(request.body["userId"] as? Int == 42)
        #expect(request.body["kinds"] as? [String] == ["followed", "companions"])

        PushWorkerProtocol.state = .init(status: 404)
        await #expect(throws: OAuthError.loginEnded) {
            try await push.subscribe(login: login, deviceToken: "abcd", sandbox: true, userID: 42, kinds: [.followed])
        }
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

    /// Likes and fellow travellers need a login that reads notifications (#447); one handed over from before
    /// #452 signs in again. A sign-up with a login of its own (before #452) is replaced by one with the app's.
    @Test func signsInAgainOnlyWhenTheLoginCantReadWhatIsWanted() {
        let own = FollowedCheckinPushSubscription(id: "a", secret: "b", usesAppLogin: false)
        let app = FollowedCheckinPushSubscription(id: "a", secret: "b")
        #expect(FollowedCheckinPush.step(for: [.followed], subscription: nil, loginReadsNotifications: false) == .signUp)
        #expect(FollowedCheckinPush.step(for: [.followed], subscription: own, loginReadsNotifications: false) == .signUp)
        #expect(FollowedCheckinPush.step(for: [.followed], subscription: app, loginReadsNotifications: false) == .update)
        #expect(FollowedCheckinPush.step(for: [.followed, .likes], subscription: app, loginReadsNotifications: false) == .signIn)
        #expect(FollowedCheckinPush.step(for: [.companions], subscription: nil, loginReadsNotifications: false) == .signIn)
        #expect(FollowedCheckinPush.step(for: [.companions], subscription: app, loginReadsNotifications: true) == .update)
        #expect(FollowedCheckinPush.step(for: [], subscription: app, loginReadsNotifications: false) == .signOff)
        #expect(FollowedCheckinPush.step(for: [], subscription: nil, loginReadsNotifications: true) == .signOff)
    }

    /// Sign-ups saved before #452 have a Träwelling login of their own.
    @Test func readsSignUpsSavedBeforeTheAppsLoginMovedToTheServer() throws {
        let saved = try JSONDecoder().decode(FollowedCheckinPushSubscription.self,
                                             from: Data(#"{"id":"a","secret":"b","readsNotifications":true}"#.utf8))
        #expect(saved == FollowedCheckinPushSubscription(id: "a", secret: "b", usesAppLogin: false))
        let again = try JSONDecoder().decode(FollowedCheckinPushSubscription.self,
                                             from: JSONEncoder().encode(FollowedCheckinPushSubscription(id: "a", secret: "b")))
        #expect(again.usesAppLogin)
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
        /// What a 200 or 201 answers, else the sign-up's `{ id, secret }` or `{}`.
        var answer: String?
        var requests: [Recorded] = []
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
        let answer = Self.state.answer.map { Data($0.utf8) }
            ?? (status == 201 ? Data(#"{"id":"new-id","secret":"new-secret"}"#.utf8) : Data("{}".utf8))
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
