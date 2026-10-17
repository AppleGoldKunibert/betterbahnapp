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

    /// "Ankunft teilen" (#317): the journey for the app, the last train for the pickup page, dates as ISO 8601.
    @Test func sharesAnArrivalWithTheJourney() async throws {
        ShareWorkerProtocol.state = .init()
        let journey = JourneyShareLinkTests.journey()
        let arrival = try #require(ArrivalShare(journey: journey, journeyId: "2|#VN#1#"))

        let url = try await client.arrivalURL(for: journey, arrival: arrival)
        #expect(url.absoluteString == "https://share.test/s/Ab3xK9zz")
        #expect(try await client.journey(id: "Ab3xK9zz") == journey)
        let sent = try #require(ShareWorkerProtocol.state.arrival)
        #expect(sent["train"] as? String == "ICE 171")
        #expect(sent["number"] as? String == "171")
        #expect(sent["product"] as? String == "highSpeed")
        #expect(sent["journeyId"] as? String == "2|#VN#1#")
        let stops = try #require(sent["stops"] as? [[String: Any]])
        #expect(stops.map { $0["eva"] as? String } == ["8002549", "8010085"])
        #expect(stops[1]["arrival"] as? String == "2026-09-21T18:13:20Z")

        // No long link to fall back to: the page needs the Worker.
        ShareWorkerProtocol.state = .init(createStatus: 503)
        await #expect(throws: TransitError.self) { try await client.arrivalURL(for: journey, arrival: arrival) }
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
        /// The last arrival sent with a journey.
        var arrivalJSON: Data?
        var arrival: [String: Any]? { arrivalJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
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
            let body = Self.body(of: request)
            if status == 201, let data = body["data"] as? String {
                let arrival = body["arrival"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                Self.lock.withLock {
                    Self._state.stored["Ab3xK9zz"] = data
                    Self._state.arrivalJSON = arrival
                }
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

    private static func body(of request: URLRequest) -> [String: Any] {
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
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}
