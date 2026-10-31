import Foundation
import Testing
@testable import BetterBahnKit

/// `TzLogClient` against a fake of our server's Tz log (#502).
@Suite(.serialized) struct TzLogTests {
    private let client = TzLogClient(http: HTTPClient(session: TzLogProtocol.session()), baseURL: TzLogProtocol.base)

    @Test func readsTheListWithSeriesNameAndLivery() async throws {
        let units = try await client.units()
        #expect(units.map(\.tz) == ["304", "4886", "8043"])
        #expect(units[0].livery == "Regenbogen")
        #expect(units[0].number == 304)
        #expect(units[1].series == "IC 2 Twindexx")
        #expect(units[2].series == "ICE 3neo")
        #expect(units[2].trains.map(\.trainName) == ["ICE 592"])
        #expect(units[2].trains[0].changedFromPlan)
        #expect(units[2].trains[0].destination == "Köln Hbf")
    }

    @Test func readsTheHistoryNewestFirstAndAsksForTheTz() async throws {
        let runs = try await client.history(of: "8043")
        #expect(TzLogProtocol.lastQuery == "tz=8043")
        #expect(runs.map(\.day) == ["2026-10-31", "2026-10-30"])
        #expect(runs[0].date != nil)
        #expect(runs[0].id == "2026-10-31|ICE|592")
    }

    /// The log's days are Germany's: just after midnight there it is already the next day, though not in UTC.
    @Test func daysAreGermanyDays() throws {
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z"))
        #expect(TzRun.day(of: lateEvening) == "2026-11-01")
        #expect(TzRun(day: "2026-11-01", category: "ICE", number: 1).date != nil)
        #expect(TzRun(day: "kaputt", category: "ICE", number: 1).date == nil)
    }

    @Test func withoutServerItThrows() async {
        let none = TzLogClient(http: HTTPClient(session: TzLogProtocol.session()), baseURL: nil)
        await #expect(throws: TransitError.self) { try await none.units() }
    }
}

final class TzLogProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://tz.test")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _query: String?
    static var lastQuery: String? { lock.withLock { _query } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TzLogProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let body: String
        switch url.path {
        case "/tz/list":
            body = """
            {"units":[
             {"tz":"304","unit":"ICE0304","types":["I4080"],"lastDay":"2026-10-31","trains":[]},
             {"tz":"4886","unit":"ICD4886","types":["E1475","R6684"],"lastDay":"2026-10-31","trains":[]},
             {"tz":"8043","unit":"ICE8043","types":["I4080","I4081"],"lastDay":"2026-10-31","trains":[
              {"day":"2026-10-31","category":"ICE","number":592,"station":"Berlin Hbf","destination":"Köln Hbf","status":"DIFFERS_FROM_SCHEDULE"}]}]}
            """
        default:
            Self.lock.withLock { Self._query = url.query }
            body = """
            {"tz":"8043","trains":[
             {"day":"2026-10-31","category":"ICE","number":592,"station":"Berlin Hbf","destination":"Köln Hbf","status":null},
             {"day":"2026-10-30","category":"ICE","number":318,"station":null,"destination":null,"status":null}]}
            """
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
