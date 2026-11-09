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

    @Test func readsTheTrainsBeforeAndAfter() async throws {
        let turnaround = try await client.turnaround(category: "ICE", number: 592, day: "2026-11-03")
        #expect(TzLogProtocol.lastQuery == "category=ICE&number=592&day=2026-11-03")
        #expect(turnaround.tz == "8043")
        #expect(turnaround.previous.map(\.name) == ["ICE 567"])
        #expect(turnaround.next.map(\.name) == ["ICE 1501", "ICE 1503"])
        #expect(turnaround.next[0].start != nil && turnaround.previous[0].startEva == "8002549")
        #expect(!turnaround.isEmpty && TzTurnaround.none.isEmpty)
    }

    /// #501: a leg's line is asked for by its train and the day it departs in Germany; other lines aren't asked at all.
    @Test func turnaroundOfALineAsksForItsTrainAndGermanDay() async throws {
        let ice = Line(name: "ICE 592", number: "592", product: .highSpeed, operatorName: nil)
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-11-02T23:30:00Z"))  // 00:30 on the 3rd in Germany
        let turnaround = try await client.turnaround(for: ice, on: lateEvening)
        #expect(TzLogProtocol.lastQuery == "category=ICE&number=592&day=2026-11-03")
        #expect(turnaround.previous.map(\.name) == ["ICE 567"])

        let regional = Line(name: "RE 5", number: "5", product: .regional, operatorName: nil)
        #expect(try await client.turnaround(for: regional, on: lateEvening).isEmpty)
        #expect(try await client.turnaround(for: nil, on: lateEvening).isEmpty)
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
        case "/tz/turnaround":
            Self.lock.withLock { Self._query = url.query }
            body = """
            {"tz":"8043",
             "previous":[{"day":"2026-11-03","category":"ICE","number":567,"start":"2026-11-03T06:00:00Z","startEva":"8002549"}],
             "next":[{"day":"2026-11-03","category":"ICE","number":1501,"start":"2026-11-03T14:00:00Z","startEva":null},
                     {"day":"2026-11-03","category":"ICE","number":1503,"start":"2026-11-03T14:00:00Z","startEva":null}]}
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

/// The train search finds trainsets by number or name (#502).
@Suite struct TzSearchTests {
    private let entries = [
        TzDescription(number: 301, series: "ICE 3", name: "Freiburg im Breisgau"),
        TzDescription(number: 304, series: "ICE 3", livery: "Regenbogen"),
        TzDescription(number: 1112, series: "ICE T", name: "Freie und Hansestadt Hamburg"),
        TzDescription(number: 1113, series: "ICE T", name: "Hamburg"),
        TzDescription(number: 1120, series: "ICE T", name: "Hansestadt Lübeck"),
        TzDescription(number: 8043, series: "ICE 3neo"),
    ]

    private func found(_ text: String) -> [Int] { TzSearch.matches(text, in: entries, limit: 8).map(\.number) }

    @Test func aPartOfTheNameIsEnough() {
        #expect(found("Hamburg") == [1113, 1112], "the exact name first")
        #expect(found("hansestadt hamburg") == [1112])
        #expect(found("Freib") == [301])
        #expect(found("breisgau") == [301])
        #expect(found("regenbogen") == [304])
    }

    @Test func accentsAndCaseDontMatter() {
        #expect(found("lubeck") == [1120])
        #expect(found("LÜBECK") == [1120])
    }

    @Test func insideAWordOnlyFromFourLetters() {
        #expect(found("burg") == [1113, 301, 1112], "inside \"Hamburg\", \"Freiburg\", \"Hamburg\"; fewer words first")
        #expect(found("urg").isEmpty, "three letters have to start a word")
        #expect(found("ham") == [1113, 1112])
    }

    @Test func tooShortOrUnknownFindsNothing() {
        #expect(found("ha").isEmpty)
        #expect(found("").isEmpty)
        #expect(found("zzzz").isEmpty)
    }

    @Test func aNumberFindsThatTrainset() {
        #expect(found("Tz 8043") == [8043])
        #expect(found("TZ8043") == [8043])
        #expect(found("triebzug 304") == [304])
        #expect(found("8043") == [8043])
        #expect(found("9999").isEmpty)
        #expect(found("12345").isEmpty, "more than four digits is a train number")
    }

    @Test func theRealListsKnowNamesAndNumbers() {
        #expect(TzSearch.matches("Hamburg").contains { $0.number == 1112 })
        #expect(TzSearch.matches("Freiburg").first?.name == "Freiburg im Breisgau")
        #expect(TzSearch.description(of: 8043)?.series == "ICE 3neo")
        #expect(TzSearch.description(of: 1)?.number == nil)
        #expect(TzSearch.matches("Tz 8043").first?.detail?.hasPrefix("ICE 3neo") == true)
        #expect(TzDescription(number: 8043).title == "Tz 8043")
    }
}
