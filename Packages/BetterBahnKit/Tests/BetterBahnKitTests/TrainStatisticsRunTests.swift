import Foundation
import Testing
@testable import BetterBahnKit

/// Old journeys get the real delays of their day from the statistics server.
@Suite(.serialized) struct TrainStatisticsRunTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func iso(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }

    private func station(_ name: String, eva: String) -> Station {
        Station(id: eva, name: name, coordinate: nil, evaNumber: eva, source: .bahnDe)
    }

    private func stop(_ station: Station, arrival: Date?, departure: Date?) -> Stopover {
        Stopover(station: station, arrival: arrival.map { TimeInfo(planned: $0, actual: nil) },
                 departure: departure.map { TimeInfo(planned: $0, actual: nil) },
                 arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    /// ICE 592 Frankfurt → Siegburg → Köln, 115 minutes after `departure` (2026-10-30 by default).
    private func leg(product: Product = .highSpeed, name: String = "ICE 592", number: String = "592",
                     departure: String = "2026-10-30T07:00:00Z", walking: Bool = false) -> Leg {
        let frankfurt = station("Frankfurt(Main)Hbf", eva: "8000105")
        let siegburg = station("Siegburg/Bonn", eva: "8003368")
        let koeln = station("Köln Hbf", eva: "8000207")
        let start = date(departure)
        return Leg(origin: frankfurt, destination: koeln,
                   departure: TimeInfo(planned: start, actual: nil),
                   arrival: TimeInfo(planned: start.addingTimeInterval(115 * 60), actual: nil),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: "t1",
                   line: Line(name: name, number: number, product: product, operatorName: nil), direction: nil,
                   isWalking: walking, cancelled: false,
                   stopovers: [
                       stop(frankfurt, arrival: nil, departure: start),
                       stop(siegburg, arrival: start.addingTimeInterval(100 * 60), departure: start.addingTimeInterval(102 * 60)),
                       stop(koeln, arrival: start.addingTimeInterval(115 * 60), departure: nil),
                   ], remarks: [], source: .transitous)
    }

    private func run(cancelled: Bool = false, _ stops: [TrainStatistics.Run.Stop]) -> TrainStatistics.Run {
        .init(day: "2026-10-30", category: "ICE", cancelled: cancelled, stops: stops)
    }

    @Test func decodesTheWorkersRun() throws {
        let json = """
        {"day":"2026-10-30","category":"ICE","cancelled":false,"stops":[
         {"eva":"8000105","arrivalDelay":null,"departureDelay":5,"platform":"7","changedPlatform":"8","cancelled":false,"additional":false},
         {"eva":"8003368","arrivalDelay":-2,"departureDelay":null,"platform":null,"changedPlatform":null,"cancelled":true},
         {"eva":"8000207","arrivalDelay":12}]}
        """
        let decoded = try JSONDecoder().decode(TrainStatistics.Run.self, from: Data(json.utf8))
        #expect(decoded.stops.map(\.eva) == ["8000105", "8003368", "8000207"])
        #expect(decoded.stops[0].departureDelay == 5 && decoded.stops[0].changedPlatform == "8")
        #expect(decoded.stops[1].arrivalDelay == -2 && decoded.stops[1].cancelled && !decoded.stops[1].additional)
        #expect(decoded.stops[2].arrivalDelay == 12 && !decoded.stops[2].cancelled)
    }

    @Test func putsTheDelaysOnTheLegAndItsStops() {
        let applied = leg().applying(run([
            .init(eva: "8000105", departureDelay: 5),
            .init(eva: "8003368", arrivalDelay: 9, departureDelay: 10),
            .init(eva: "8000207", arrivalDelay: 12),
        ]), now: now)
        #expect(applied.departure.delayMinutes == 5)
        #expect(applied.arrival.delayMinutes == 12)
        #expect(applied.stopovers[1].arrival?.delayMinutes == 9 && applied.stopovers[1].departure?.delayMinutes == 10)
        #expect(applied.stopovers[0].departure?.delayMinutes == 5 && applied.stopovers[2].arrival?.delayMinutes == 12)
        #expect(!applied.cancelled)
    }

    @Test func anEarlyTrainHasANegativeDelay() throws {
        let applied = leg().applying(run([.init(eva: "8000207", arrivalDelay: -3)]), now: now)
        #expect(applied.arrival.delayMinutes == -3)
        let actual = try #require(applied.arrival.actual)
        #expect(actual < applied.arrival.planned)
        #expect(applied.departure.actual == nil, "a stop the run says nothing about stays planned")
    }

    @Test func aCancelledStopIsMarkedAndGetsNoTime() {
        let applied = leg().applying(run([
            .init(eva: "8000105", departureDelay: 0),
            .init(eva: "8003368", cancelled: true),
            .init(eva: "8000207", arrivalDelay: 4),
        ]), now: now)
        #expect(applied.stopovers[1].cancelled)
        #expect(applied.stopovers[1].arrival?.actual == nil)
        #expect(!applied.cancelled && !applied.stopovers[0].cancelled)
    }

    @Test func aCancelledRunCancelsTheLeg() {
        let applied = leg().applying(run(cancelled: true, []), now: now)
        #expect(applied.cancelled)
        #expect(applied.stopovers.allSatisfy { $0.cancelled })
        #expect(!applied.hasActualTimes)
    }

    @Test func neverOverwritesLiveData() {
        var live = leg()
        live.arrival.actual = live.arrival.planned.addingTimeInterval(60)
        #expect(live.applying(run([.init(eva: "8000207", arrivalDelay: 30)]), now: now) == live)

        var stopOnly = leg()
        let planned = stopOnly.stopovers[1].arrival?.planned
        stopOnly.stopovers[1].arrival?.actual = planned
        #expect(stopOnly.applying(run([.init(eva: "8000207", arrivalDelay: 30)]), now: now) == stopOnly)
    }

    @Test func leavesALegThatIsStillRecentAlone() {
        let recent = leg(departure: "2026-11-04T10:30:00Z")
        #expect(recent.applying(run([.init(eva: "8000207", arrivalDelay: 30)]), now: now) == recent)
        #expect(recent.statisticsRunQuery(now: now) == nil)
    }

    @Test func foldsTheLowerLevelOfABigStationIntoItsMainStation() {
        var berlin = leg()
        berlin.origin = station("Berlin Hbf (tief)", eva: "8098160")
        berlin.stopovers[0].station = berlin.origin
        let applied = berlin.applying(run([.init(eva: "8011160", departureDelay: 7)]), now: now)
        #expect(applied.departure.delayMinutes == 7)
        #expect(applied.stopovers[0].departure?.delayMinutes == 7)
    }

    @Test func asksOnlyForWhatTheServerKeeps() throws {
        let query = try #require(leg().statisticsRunQuery(now: now))
        #expect(query.day == "2026-10-30")
        #expect(query.train.category == "ICE" && query.train.number == "592")
        #expect(query.train.evas == ["8000105", "8000207"])

        // Long-distance trains for about a year, regional ones for 30 days, nothing for a walk.
        #expect(leg(departure: "2026-02-01T07:00:00Z").statisticsRunQuery(now: now) != nil)
        #expect(leg(departure: "2025-06-01T07:00:00Z").statisticsRunQuery(now: now) == nil)
        let regional = leg(product: .regionalExpress, name: "RE 5", number: "5", departure: "2026-09-20T07:00:00Z")
        #expect(regional.statisticsRunQuery(now: now) == nil)
        #expect(leg(walking: true).statisticsRunQuery(now: now) == nil)

        var live = leg()
        live.departure.actual = live.departure.planned
        #expect(live.statisticsRunQuery(now: now) == nil)
    }

    @Test func asksWithTheDayAndMatchesTheAnswersInOrder() async throws {
        let client = TrainStatisticsClient(http: HTTPClient(session: StatsRunProtocol.session()),
                                           baseURL: URL(string: "https://stats.test")!)
        let ice = TrainStatisticsClient.RunQuery(train: .init(category: "ICE", number: "592", evas: ["8000105"]), day: "2026-10-30")
        let ic = TrainStatisticsClient.RunQuery(train: .init(category: "IC", number: "2049", evas: ["8000152"]), day: "2026-10-29")
        let answers = try await client.runs(for: [ice, ic])
        // The second train has no run (null): left out.
        #expect(answers.count == 1)
        #expect(answers[ice]?.stops.first?.departureDelay == 5)
        #expect(answers[ic] == nil)
        let sent = try #require(StatsRunProtocol.lastBody)
        #expect(sent.contains("\"day\":\"2026-10-30\"") && sent.contains("\"day\":\"2026-10-29\""))
        #expect(sent.contains("\"number\":\"2049\""))
    }

    /// An older Worker ignores `day` and answers without `run`: that is no answer for the day, so the app must not
    /// remember "no run" (it would never ask again) but ask again later.
    @Test func aWorkerThatDoesntKnowDaysIsNotTakenForNoRun() async throws {
        let client = TrainStatisticsClient(http: HTTPClient(session: StatsRunProtocol.session()),
                                           baseURL: URL(string: "https://stats.test")!)
        StatsRunProtocol.oldWorker = true
        defer { StatsRunProtocol.oldWorker = false }
        let ice = TrainStatisticsClient.RunQuery(train: .init(category: "ICE", number: "592", evas: ["8000105"]), day: "2026-10-30")
        await #expect(throws: TrainStatisticsClient.RunError.self) { try await client.runs(for: [ice]) }
    }

    @Test func aQueryKnowsWhenItsDayBegan() throws {
        let query = try #require(leg().statisticsRunQuery(now: now))
        // 2026-10-30 00:00 in Germany is 23:00 UTC the evening before (winter time since 25 October).
        #expect(query.dayStart == date("2026-10-29T23:00:00Z"))
        let broken = TrainStatisticsClient.RunQuery(train: query.train, day: "kaputt")
        #expect(broken.dayStart == .distantPast)
    }

    @Test func appliesRunsToAJourneyByLegID() {
        let first = leg()
        let journey = Journey(legs: [first], source: .transitous)
        let applied = journey.applying([first.id: run([.init(eva: "8000207", arrivalDelay: 6)])], now: now)
        #expect(applied.legs[0].arrival.delayMinutes == 6)
        #expect(journey.applying([:], now: now) == journey)
        #expect(journey.applying(["other": run([.init(eva: "8000207", arrivalDelay: 6)])], now: now) == journey)
    }
}

/// A fake statistics Worker: answers two trains, the first with a run, the second with `null`.
final class StatsRunProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _body: String?
    static var lastBody: String? { lock.withLock { _body } }
    /// Answers like the Worker before it knew days: no `run` key at all.
    nonisolated(unsafe) private static var _oldWorker = false
    static var oldWorker: Bool {
        get { lock.withLock { _oldWorker } }
        set { lock.withLock { _oldWorker = newValue } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatsRunProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lock.withLock { Self._body = String(data: data, encoding: .utf8) }
        let body = Self.oldWorker ? """
        {"trains":[{"category":"ICE","number":"592","days":30,"runs":20,"cancelled":0,"stops":{}}]}
        """ : """
        {"trains":[
         {"category":"ICE","number":"592","days":30,"runs":20,"cancelled":0,"stops":{},
          "run":{"day":"2026-10-30","category":"ICE","cancelled":false,"stops":[{"eva":"8000105","arrivalDelay":null,"departureDelay":5}]}},
         {"category":"IC","number":"2049","days":30,"runs":10,"cancelled":0,"stops":{},"run":null}]}
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
