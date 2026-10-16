import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// The figures of `Cloudflare/stats` (`POST /train-stats`) as the app reads them (#316).
@Suite(.serialized) struct TrainStatisticsTests {
    /// What the Worker answers for ICE 1095: 12 runs, one cancelled, the arrival delays and platform moves at Fulda.
    static let response = #"""
    {"trains":[{
      "category":"ICE","number":"1095","days":30,"runs":12,"cancelled":1,
      "stops":{
        "8000115":{"runs":12,"cancelled":2,"arrival":[0,1,2,3,5,6,8,12,20,-1],"departure":[1,1,2],
          "platforms":[{"from":"7","to":"7","n":6},{"from":"7","to":"8","n":2},{"from":"7","to":"9","n":1},{"from":"4","to":"4","n":1}]}
      }
    }]}
    """#

    private func decoded() throws -> TrainStatistics {
        let decoded = try JSONDecoder().decode([String: [TrainStatistics]].self, from: Data(Self.response.utf8))
        return try #require(decoded["trains"]?.first)
    }

    @Test func readsRunsAndCancellations() throws {
        let train = try decoded()
        #expect(train.runs == 12)
        #expect(train.cancelledRuns == 1)
        #expect(abs(try #require(train.cancelledShare) - 1.0 / 12.0) < 0.001)
    }

    @Test func summarisesDelaysAtAStop() throws {
        let stop = try #require(try decoded().stops["8000115"])
        let arrival = try #require(stop.arrivalSummary())
        #expect(arrival.runs == 10)
        // (0+1+2+3+5+6+8+12+20-1) / 10 = 5.6
        #expect(arrival.average == 6)
        // Up to +5 counts as on time: 0, 1, 2, 3, 5 and -1.
        #expect(abs(arrival.onTimeShare - 0.6) < 0.001)
        // Three departures are too few to say anything.
        #expect(stop.departureSummary() == nil)
    }

    @Test func givesTheChanceToArriveTooLateForATransfer() throws {
        let stop = try #require(try decoded().stops["8000115"])
        // 6, 8, 12 and 20 are at least 6 minutes late.
        #expect(abs(try #require(stop.arrivalLateShare(atLeast: 6)) - 0.4) < 0.001)
        #expect(abs(try #require(stop.arrivalLateShare(atLeast: 15)) - 0.1) < 0.001)
        #expect(TrainStatistics.Stop(runs: 3, arrival: [1, 2, 30]).arrivalLateShare(atLeast: 5) == nil)
    }

    @Test func testModeShowsFiguresFromASingleRun() {
        let stop = TrainStatistics.Stop(runs: 1, arrival: [4])
        #expect(stop.arrivalSummary() == nil)
        TrainStatistics.testMode = true
        defer { TrainStatistics.testMode = false }
        #expect(stop.arrivalSummary()?.average == 4)
        #expect(TrainStatistics(category: "ICE", number: "1", runs: 1).cancelledShare == 0)
    }

    @Test func givesTheChanceOfACancelledStop() throws {
        let stop = try #require(try decoded().stops["8000115"])
        #expect(abs(try #require(stop.cancelledShare) - 2.0 / 12.0) < 0.001)
        #expect(TrainStatistics.Stop(runs: 4, cancelled: 2).cancelledShare == nil)
    }

    @Test func listsTheOtherPlatformsMostLikelyFirst() throws {
        let stop = try #require(try decoded().stops["8000115"])
        // Planned for Gl. 7: 6 runs there, 2 on Gl. 8, 1 on Gl. 9.
        let outlook = try #require(stop.platformOutlook(planned: "7"))
        #expect(outlook.runs == 9)
        #expect(abs(outlook.changeShare - 3.0 / 9.0) < 0.001)
        #expect(outlook.alternatives.map(\.platform) == ["8", "9"])
        #expect(abs(outlook.alternatives[0].share - 2.0 / 9.0) < 0.001)
        // One run planned for Gl. 4 is too few; no platform means no answer.
        #expect(stop.platformOutlook(planned: "4") == nil)
        #expect(stop.platformOutlook(planned: nil) == nil)
        #expect(stop.platformOutlook(planned: "12") == nil)
    }

    @Test func buildsAQueryForRegionalAndLongDistanceTrainsOnly() {
        let ice = Line(name: "ICE 1095", number: "1095", product: .highSpeed, operatorName: nil)
        #expect(TrainStatisticsQuery(line: ice, evas: ["8000115", "8003200", "8000115"]) == .init(category: "ICE", number: "1095", evas: ["8000115", "8003200"]))

        // A regional train is known by its run number, not its line.
        let re = Line(name: "RE 5", number: "5", product: .regionalExpress, operatorName: nil, tripNumber: "4530")
        #expect(TrainStatisticsQuery(line: re, evas: ["8000115"])?.number == "4530")
        #expect(TrainStatisticsQuery(line: re, evas: ["8000115"])?.category == "RE")
        // Without the run number only the line's is known, which would match another train.
        let unnumbered = Line(name: "RE 5", number: "5", product: .regionalExpress, operatorName: nil)
        #expect(TrainStatisticsQuery(line: unnumbered, evas: ["8000115"]) == nil)

        let sBahn = Line(name: "S 1", number: "1", product: .suburban, operatorName: nil)
        #expect(TrainStatisticsQuery(line: sBahn, evas: ["8000115"]) == nil)
        #expect(TrainStatisticsQuery(line: ice, evas: []) == nil)
        #expect(TrainStatisticsQuery(line: nil, evas: ["8000115"]) == nil)
    }
}

/// Tight transfers and what the incoming train usually does there (#316).
@Suite struct TightTransferTests {
    private func station(_ eva: String, _ name: String) -> Station {
        Station(id: eva, name: name, coordinate: nil, evaNumber: eva, source: .bahnDe)
    }

    private func leg(_ line: String, product: Product = .highSpeed, from: Station, to: Station, departing: TimeInterval, minutes: Double) -> Leg {
        let start = Date(timeIntervalSince1970: 1_790_000_000 + departing * 60)
        let number = String(line.split(separator: " ").last ?? "")
        return Leg(origin: from, destination: to, departure: TimeInfo(planned: start, actual: nil),
                   arrival: TimeInfo(planned: start.addingTimeInterval(minutes * 60), actual: nil),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: line,
                   line: Line(name: line, number: number, product: product, operatorName: nil),
                   direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    private var journey: Journey {
        let hamburg = station("8002549", "Hamburg Hbf"), fulda = station("8000115", "Fulda"), munich = station("8000261", "München Hbf")
        // ICE 578 arrives in Fulda at +120 min; the connection leaves 6 minutes later, the next one an hour later.
        return Journey(legs: [
            leg("ICE 578", from: hamburg, to: fulda, departing: 0, minutes: 120),
            leg("RE 5", product: .regionalExpress, from: fulda, to: station("8000105", "Frankfurt"), departing: 126, minutes: 60),
            leg("ICE 71", from: station("8000105", "Frankfurt"), to: munich, departing: 246, minutes: 180),
        ], source: .bahnDe)
    }

    @Test func picksTheTransfersWithLittleTime() throws {
        let transfers = journey.tightTransfers()
        #expect(transfers.map(\.bufferMinutes) == [6])
        let transfer = try #require(transfers.first)
        #expect(transfer.station.name == "Fulda")
        #expect(transfer.line?.name == "ICE 578")
        // The second transfer has 60 minutes; with a higher limit it counts too.
        #expect(journey.tightTransfers(upTo: 90).count == 2)
    }

    @Test func warnsWhenTheIncomingTrainOftenArrivesTooLate() throws {
        let late = TrainStatistics.Stop(runs: 10, arrival: [0, 2, 4, 6, 7, 8, 9, 10, 12, 20])
        let outlook = try #require(late.transferOutlook(bufferMinutes: 6))
        #expect(outlook.bufferMinutes == 6)
        // 6, 7, 8, 9, 10, 12 and 20 minutes late miss it.
        #expect(abs(outlook.lateShare - 0.7) < 0.001)
        #expect(outlook.averageDelay == 8)
        #expect(outlook.isRisky)

        let punctual = TrainStatistics.Stop(runs: 10, arrival: [0, 0, 1, 1, 2, 2, 3, 3, 4, 9])
        #expect(try #require(punctual.transferOutlook(bufferMinutes: 6)).isRisky == false)
        #expect(TrainStatistics.Stop(runs: 3, arrival: [9, 9, 9]).transferOutlook(bufferMinutes: 6) == nil)
    }

    @Test func leavesOutTransfersOfTrainsTheServerDoesNotCollect() {
        let a = station("8000001", "A"), b = station("8000002", "B"), c = station("8000003", "C")
        let journey = Journey(legs: [
            leg("S 1", product: .suburban, from: a, to: b, departing: 0, minutes: 30),
            leg("ICE 71", from: b, to: c, departing: 35, minutes: 30),
        ], source: .bahnDe)
        #expect(journey.tightTransfers().isEmpty)
    }
}

/// `TrainStatisticsClient` and `TrainStatisticsStore` against a fake `betterbahn-stats` Worker.
@Suite(.serialized) struct TrainStatisticsLookupTests {
    private func client() -> TrainStatisticsClient {
        TrainStatisticsClient(http: HTTPClient(session: StatsWorkerProtocol.session()), baseURL: StatsWorkerProtocol.base)
    }

    private func store(now: @escaping @Sendable () -> Date = { Date() }) -> TrainStatisticsStore {
        let client = client()
        return TrainStatisticsStore(now: now) { queries in try await client.statistics(for: queries) }
    }

    private let ice = TrainStatisticsQuery(category: "ICE", number: "1095", evas: ["8000115"])

    @Test func postsTheTrainsAndReadsTheFigures() async throws {
        StatsWorkerProtocol.reset(status: 200)
        let answers = try await client().statistics(for: [ice])
        #expect(answers.map(\.number) == ["1095"])
        #expect(StatsWorkerProtocol.requests.count == 1)
        #expect(StatsWorkerProtocol.requests[0].path == "/train-stats")
        #expect(StatsWorkerProtocol.requests[0].trains == ["ICE|1095|8000115"])
    }

    @Test func sendsAtMostEightTrainsPerRequest() async throws {
        StatsWorkerProtocol.reset(status: 200)
        let queries = (0..<10).map { TrainStatisticsQuery(category: "ICE", number: "\(1000 + $0)", evas: ["8000115"]) }
        _ = try await client().statistics(for: queries)
        #expect(StatsWorkerProtocol.requests.map(\.trains.count) == [8, 2])
    }

    @Test func asksOnlyOncePerTrainDayAndStop() async {
        StatsWorkerProtocol.reset(status: 200)
        let store = store()
        await store.setEnabled(true)
        let first = await store.statistics(for: [ice], day: "2026-10-14")
        #expect(first["ICE|1095|2026-10-14"]?.runs == 12)
        _ = await store.statistics(for: [ice], day: "2026-10-14")
        #expect(StatsWorkerProtocol.requests.count == 1)

        // Another stop of the same train is asked for; the first one's figures stay.
        let kassel = TrainStatisticsQuery(category: "ICE", number: "1095", evas: ["8000115", "8003200"])
        let merged = await store.statistics(for: [kassel], day: "2026-10-14")
        #expect(StatsWorkerProtocol.requests.count == 2)
        #expect(StatsWorkerProtocol.requests[1].trains == ["ICE|1095|8003200"])
        #expect(merged["ICE|1095|2026-10-14"]?.stops["8000115"] != nil)

        // The next day asks again.
        _ = await store.statistics(for: [ice], day: "2026-10-15")
        #expect(StatsWorkerProtocol.requests.count == 3)
        #expect(await store.cached(ice, day: "2026-10-15")?.runs == 12)
    }

    @Test func findsTheStopsOfALegAndLooksUpMissingEVANumbers() async throws {
        StatsWorkerProtocol.reset(status: 200)
        let store = store()
        await store.setEnabled(true)
        let fulda = Station(id: "8000115", name: "Fulda", coordinate: nil, evaNumber: "8000115", source: .bahnDe)
        let kassel = Station(id: "de-DELFI_kassel", name: "Kassel-Wilhelmshöhe", coordinate: nil, evaNumber: nil, source: .transitous)
        let line = Line(name: "ICE 1095", number: "1095", product: .highSpeed, operatorName: nil)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let lookup = try #require(await store.lookup(line: line, at: [fulda, kassel], on: date) { $0.name.hasPrefix("Kassel") ? "8003200" : nil })
        #expect(lookup.stop(at: fulda)?.runs == 12)
        #expect(lookup.stop(at: kassel)?.runs == 12)
        #expect(StatsWorkerProtocol.requests[0].trains == ["ICE|1095|8000115,8003200"])

        // S-Bahn isn't collected.
        let sBahn = Line(name: "S 1", number: "1", product: .suburban, operatorName: nil)
        #expect(await store.lookup(line: sBahn, at: [fulda], on: date) == nil)
    }

    @Test func ratesTightTransfersByTheIncomingTrainsUsualDelay() async {
        StatsWorkerProtocol.reset(status: 200)
        let store = store()
        await store.setEnabled(true)
        let fulda = Station(id: "8000115", name: "Fulda", coordinate: nil, evaNumber: "8000115", source: .bahnDe)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let ice = Line(name: "ICE 1095", number: "1095", product: .highSpeed, operatorName: nil)
        let tight = TightTransfer(id: "a", line: ice, station: fulda, bufferMinutes: 4, arrival: date)
        let relaxed = TightTransfer(id: "b", line: ice, station: fulda, bufferMinutes: 9, arrival: date)
        let unknown = TightTransfer(id: "c", line: Line(name: "ICE 9999", number: "9999", product: .highSpeed, operatorName: nil),
                                    station: fulda, bufferMinutes: 4, arrival: date)
        let outlooks = await store.outlooks(for: [tight, relaxed, unknown])
        // The fake's arrivals are 0…5 minutes late: 4 and 5 of them miss a 4-minute transfer, none a 9-minute one.
        #expect(outlooks["a"]?.isRisky == true)
        #expect(outlooks["b"]?.lateShare == 0)
        #expect(outlooks["c"] == nil)
        #expect(StatsWorkerProtocol.requests.count == 1, "one request for all of them")
    }

    @Test func asksNothingWhileSwitchedOff() async {
        StatsWorkerProtocol.reset(status: 200)
        let store = store()
        #expect(await store.statistics(for: [ice], day: "2026-10-14").isEmpty)
        await store.setEnabled(true)
        _ = await store.statistics(for: [ice], day: "2026-10-14")
        await store.setEnabled(false)
        #expect(await store.cached(ice, day: "2026-10-14") == nil)
        #expect(StatsWorkerProtocol.requests.count == 1)
    }

    @Test func waitsBeforeAskingAgainAfterAFailure() async {
        StatsWorkerProtocol.reset(status: 503)
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let store = store(now: { clock.withLock { $0 } })
        await store.setEnabled(true)
        #expect(await store.statistics(for: [ice], day: "2026-10-14").isEmpty)
        #expect(await store.statistics(for: [ice], day: "2026-10-14").isEmpty)
        #expect(StatsWorkerProtocol.requests.count == 1, "not hammering a Worker that is down")

        clock.withLock { $0 = $0.addingTimeInterval(6 * 60) }
        StatsWorkerProtocol.reset(status: 200)
        #expect(await store.statistics(for: [ice], day: "2026-10-14")["ICE|1095|2026-10-14"]?.runs == 12)
    }

    @Test func trainsTheServerKnowsNothingAboutAreLeftOut() async {
        StatsWorkerProtocol.reset(status: 200)
        let store = store()
        await store.setEnabled(true)
        let unknown = TrainStatisticsQuery(category: "ICE", number: "9999", evas: ["8000115"])
        let result = await store.statistics(for: [ice, unknown], day: "2026-10-14")
        #expect(Set(result.keys) == ["ICE|1095|2026-10-14"])
    }
}

final class StatsWorkerProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://stats.test")!

    struct Recorded {
        var path: String
        /// "ICE|1095|8000115,8003200" per train.
        var trains: [String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [Recorded] = []
    nonisolated(unsafe) private static var _status = 200
    static var requests: [Recorded] { lock.withLock { _requests } }

    static func reset(status: Int) {
        lock.withLock {
            _requests = []
            _status = status
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatsWorkerProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        struct Body: Decodable {
            struct Train: Decodable { var category: String; var number: String; var evas: [String] }
            var trains: [Train]
        }
        let body = Self.body(of: request).flatMap { try? JSONDecoder().decode(Body.self, from: $0) }
        let trains = body?.trains ?? []
        let status = Self.lock.withLock { () -> Int in
            Self._requests.append(Recorded(path: request.url!.path,
                                           trains: trains.map { "\($0.category)|\($0.number)|\($0.evas.joined(separator: ","))" }))
            return Self._status
        }
        // Only ICE 1095 has figures; the others are left out of the answer.
        var answers = ""
        if status == 200 {
            let known = trains.filter { $0.number == "1095" }
            answers = known.map { Self.answer(for: $0.evas) }.joined(separator: ",")
        }
        let json = status == 200 ? #"{"trains":[\#(answers)]}"# : #"{"error":"down"}"#
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func answer(for evas: [String]) -> String {
        let stops = evas.map { #""\#($0)":{"runs":12,"cancelled":0,"arrival":[0,1,2,3,4,5],"departure":[],"platforms":[]}"# }
        return #"{"category":"ICE","number":"1095","days":30,"runs":12,"cancelled":0,"formations":[],"stops":{\#(stops.joined(separator: ","))}}"#
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&chunk, maxLength: chunk.count)
            if count <= 0 { break }
            buffer.append(chunk, count: count)
        }
        return buffer
    }
}
