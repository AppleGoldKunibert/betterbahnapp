import Foundation
import Testing
@testable import BetterBahnKit

/// Importing a long check-in history for the map (#170): Träwelling rate-limits, so a 429 is waited
/// out instead of failing the whole import, and every page hands back only the check-ins not seen yet.
@Suite(.serialized) struct TraewellingHistoryImportTests {
    @Test func waitsOutARateLimitAndReturnsOnlyNewCheckins() async throws {
        HistoryPageProtocol.requests = []
        HistoryPageProtocol.rateLimitsLeft = 1
        let page = try await client().historyPage(username: "alfred", page: 2, knownIDs: [101],
                                                  rateLimitDelays: [.milliseconds(1)])

        #expect(page.trips.map(\.statusID) == [103, 102])
        #expect(page.reachedKnown)
        #expect(page.hasMore)
        #expect(page.trips.first?.journey.legs.first?.geometry?.count == 2)
        #expect(page.trips.last?.journey.legs.first?.geometry == nil)
        #expect(HistoryPageProtocol.requests == [
            "/api/v1/user/alfred/statuses?page=2",
            "/api/v1/user/alfred/statuses?page=2",
            "/api/v1/polyline/103,102",
        ])
    }

    @Test func givesUpWhenStillRateLimitedAfterWaiting() async throws {
        HistoryPageProtocol.requests = []
        HistoryPageProtocol.rateLimitsLeft = 5
        await #expect(throws: TransitError.rateLimited) {
            try await client().historyPage(username: "alfred", page: 1, knownIDs: [],
                                           rateLimitDelays: [.milliseconds(1), .milliseconds(1)])
        }
        #expect(HistoryPageProtocol.requests.count == 3)
    }

    private func client() -> TraewellingClient {
        let store = TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        store.save(OAuthToken(accessToken: "test-token", refreshToken: nil, expiresAt: .distantFuture))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryPageProtocol.self]
        return TraewellingClient(config: TraewellingConfig(clientID: "public-client"),
                                 http: HTTPClient(session: URLSession(configuration: configuration)), store: store)
    }
}

/// Answers the statuses request with 429 `rateLimitsLeft` times, then with three check-ins
/// (103, 102, 101) and a next page; geometry only exists for 103.
private final class HistoryPageProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var rateLimitsLeft = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.append(url.path + (url.query.map { "?\($0)" } ?? ""))
        var status = 200
        var body = ""
        if url.path.contains("/statuses") {
            if Self.rateLimitsLeft > 0 {
                Self.rateLimitsLeft -= 1
                status = 429
            } else {
                let statuses = [103, 102, 101].map(Self.status).joined(separator: ",")
                body = #"{"data":[\#(statuses)],"links":{"next":"https://traewelling.de/api/v1/user/alfred/statuses?page=3"}}"#
            }
        } else if url.path.contains("/polyline/") {
            body = #"{"data":{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"LineString","coordinates":[[6.958,50.943],[9.741,52.376]]},"properties":{"statusId":103}}]}}"#
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func status(_ id: Int) -> String {
        """
        {"id":\(id),"createdAt":"2026-09-10T08:00:00+00:00","checkin":{"trip":5,"category":"nationalExpress","lineName":"ICE 645","journeyNumber":645,
        "origin":{"name":"Köln Hbf","station":{"id":1,"name":"Köln Hbf","latitude":50.943,"longitude":6.958},"departurePlanned":"2026-09-10T08:12:00+00:00"},
        "destination":{"name":"Hannover Hbf","station":{"id":2,"name":"Hannover Hbf","latitude":52.376,"longitude":9.741},"arrivalPlanned":"2026-09-10T10:54:00+00:00"}}}
        """
    }
}
