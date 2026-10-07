import Foundation
import Testing
@testable import BetterBahnKit

/// `ShortShareLinkClient` against a fake `betterbahn` Worker (`ShareWorkerProtocol`).
@Suite(.serialized) struct ShortShareLinkClientTests {
    private let client = ShortShareLinkClient(http: HTTPClient(session: ShareWorkerProtocol.session()),
                                              baseURL: ShareWorkerProtocol.base)

    @Test func sharesAShortLinkThatResolvesToTheJourney() async throws {
        ShareWorkerProtocol.state = .init()
        let journey = JourneyShareLinkTests.journey()

        let url = try #require(await client.shareURL(for: journey))
        #expect(url.absoluteString == "https://share.test/s/Ab3xK9zz")
        #expect(ShareWorkerProtocol.state.stored["Ab3xK9zz"].flatMap(JourneyShareLink.journey(fromPayload:)) == journey)
        #expect(try await client.journey(id: "Ab3xK9zz") == journey)
    }

    /// Offline, refused or rate limited: the long link still works, and old long links keep working.
    @Test func fallsBackToTheLongLinkWhenTheWorkerFails() async throws {
        for status in [401, 429, 503] {
            ShareWorkerProtocol.state = .init(createStatus: status)
            let journey = JourneyShareLinkTests.journey()
            let url = try #require(await client.shareURL(for: journey))
            #expect(url.scheme == "betterbahn")
            #expect(JourneyShareLink.journey(from: url) == journey)
        }
    }

    @Test func reportsExpiredAndBrokenLinks() async throws {
        ShareWorkerProtocol.state = .init(stored: ["Broken12": "not-a-journey"])
        await #expect(throws: ShortShareLinkError.expired) { try await client.journey(id: "Gone1234") }
        await #expect(throws: ShortShareLinkError.invalid) { try await client.journey(id: "Broken12") }
        await #expect(throws: ShortShareLinkError.invalid) { try await client.journey(id: "../x") }
    }
}

final class ShareWorkerProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://share.test")!

    struct State {
        var stored: [String: String] = [:]
        var createStatus = 201
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _state = State()
    static var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareWorkerProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        var status = 404
        var response = #"{"error":"not_found"}"#
        if path == "/share", request.httpMethod == "POST" {
            status = Self.state.createStatus
            if status == 201, let data = Self.body(of: request)["data"] {
                Self.lock.withLock { Self._state.stored["Ab3xK9zz"] = data }
                response = #"{"id":"Ab3xK9zz","url":"https://share.test/s/Ab3xK9zz","expiresAt":"2026-11-03T00:00:00Z"}"#
            } else {
                response = #"{"error":"refused"}"#
            }
        } else if path.hasPrefix("/share/"), let data = Self.state.stored[String(path.dropFirst("/share/".count))] {
            status = 200
            response = #"{"data":"\#(data)"}"#
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> [String: String] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                if count <= 0 { break }
                buffer.append(chunk, count: count)
            }
            data = buffer
        }
        return data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}
