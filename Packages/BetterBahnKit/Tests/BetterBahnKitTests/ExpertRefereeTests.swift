import Foundation
import Testing
@testable import BetterBahnKit

/// Where bahn.de and DB Timetables disagree on a stop, bahn.expert is asked which one is right: the value
/// closer to bahn.expert's stays, DB Timetables' on a tie.
struct ExpertRefereeTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ minutes: TimeInterval) -> Date { now.addingTimeInterval(minutes * 60) }

    func stopover(_ id: String, _ minutes: TimeInterval, delay: TimeInterval?) -> Stopover {
        let time = TimeInfo(planned: at(minutes), actual: delay.map { at(minutes + $0) })
        return Stopover(station: station(id, id, source: .bahnDe), arrival: time, departure: time,
                        arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    func bahnDeStop(_ id: String, _ minutes: TimeInterval, delay: TimeInterval) -> JourneyStop {
        let time = TimeInfo(planned: at(minutes), actual: at(minutes + delay))
        return JourneyStop(evaNumber: id, name: id, arrival: time, departure: time)
    }

    func expert(_ id: String, _ minutes: TimeInterval, delay: TimeInterval) -> ExpertTimes {
        ExpertTimes(entries: [
            .init(eva: id, planned: at(minutes), actual: at(minutes + delay), side: .arrival),
            .init(eva: id, planned: at(minutes), actual: at(minutes + delay), side: .departure),
        ])
    }

    func delays(_ stopovers: [Stopover]) -> [Int?] { stopovers.map { $0.departure?.delayMinutes } }

    func apply(timetables: TimeInterval?, bahnDe: TimeInterval, expert expertDelay: TimeInterval?) -> Int? {
        let own = [stopover("hamburg", 0, delay: timetables)]
        let live = [bahnDeStop("hamburg", 0, delay: bahnDe)]
        let referee = expertDelay.map { expert("hamburg", 0, delay: $0) }
        return delays(BahnDeClient.applyingLiveTimes(from: live, to: own, keepingDelays: true, expert: referee))[0]
    }

    @Test func theValueCloserToBahnExpertStays() {
        // RE 3 3354: DB Timetables +19, bahn.de +7. bahn.expert agrees with DB.
        #expect(apply(timetables: 19, bahnDe: 7, expert: 19) == 19)
        // bahn.expert agrees with bahn.de: it wins here.
        #expect(apply(timetables: 19, bahnDe: 7, expert: 7) == 7)
        // In between: the closer one.
        #expect(apply(timetables: 19, bahnDe: 7, expert: 10) == 7)
        #expect(apply(timetables: 19, bahnDe: 7, expert: 16) == 19)
    }

    @Test func aTieStaysWithDBTimetables() {
        #expect(apply(timetables: 19, bahnDe: 7, expert: 13) == 19)
    }

    @Test func anOnTimeStopDBTimetablesInferredGivesWayToBahnDeOnlyIfBahnExpertAgrees() {
        // DB Timetables has no change for the stop (on time), bahn.de has +7.
        #expect(apply(timetables: 0, bahnDe: 7, expert: 7) == 7)
        #expect(apply(timetables: 0, bahnDe: 7, expert: 0) == 0)
        // Without bahn.expert's answer the rule is the one before: bahn.de fills an on-time stop.
        #expect(apply(timetables: 0, bahnDe: 7, expert: nil) == 7)
        #expect(apply(timetables: 19, bahnDe: 7, expert: nil) == 19)
    }

    @Test func anEarlyTimeIsNeverTurnedIntoOnTime() {
        // bahn.de shows an early train as ±0; even a bahn.expert that sides with it can't undo that rule.
        #expect(apply(timetables: -10, bahnDe: 0, expert: 0) == -10)
        #expect(apply(timetables: -10, bahnDe: 0, expert: -10) == -10)
    }

    @Test func aStopBahnExpertDoesNotKnowIsDecidedAsBefore() {
        let own = [stopover("hamburg", 0, delay: 19)]
        let live = [bahnDeStop("hamburg", 0, delay: 7)]
        let other = expert("kiel", 0, delay: 7)
        #expect(delays(BahnDeClient.applyingLiveTimes(from: live, to: own, keepingDelays: true, expert: other)) == [19])
    }

    @Test func theLegsEndsFollowTheRefereeToo() {
        let leg = Leg(origin: station("hamburg", "hamburg", source: .bahnDe), destination: station("berlin", "berlin", source: .bahnDe),
                      departure: TimeInfo(planned: at(0), actual: at(19)), arrival: TimeInfo(planned: at(100), actual: at(119)),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "3354",
                      line: Line(name: "RE 3", number: nil, product: .regionalExpress, operatorName: nil), direction: nil,
                      isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        let live = [bahnDeStop("hamburg", 0, delay: 7), bahnDeStop("berlin", 100, delay: 7)]
        let referee = ExpertTimes(entries: expert("hamburg", 0, delay: 7).entries + expert("berlin", 100, delay: 7).entries)

        let result = BahnDeClient.applyingLiveTimes(from: live, to: leg, keepingDelays: true, expert: referee)

        #expect(result.departure.delayMinutes == 7)
        #expect(result.arrival.delayMinutes == 7)
    }

    @Test func recognisesWhenBahnDeAndDBTimetablesDisagree() {
        let own = [stopover("a", 0, delay: 19), stopover("b", 10, delay: 5)]
        #expect(BahnDeClient.disagrees([bahnDeStop("a", 0, delay: 7)], with: own))
        // Within a minute is the same time; a stop bahn.de doesn't know can't disagree.
        #expect(!BahnDeClient.disagrees([bahnDeStop("a", 0, delay: 19), bahnDeStop("b", 10, delay: 5)], with: own))
        #expect(!BahnDeClient.disagrees([bahnDeStop("c", 0, delay: 7)], with: own))
        // Nothing to disagree about while DB Timetables has no time for the stop.
        #expect(!BahnDeClient.disagrees([bahnDeStop("a", 0, delay: 7)], with: [stopover("a", 0, delay: nil)]))
    }

    @Test func readsBahnExpertsLiveTimesForARun() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExpertRunProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = BahnExpertClient(http: HTTPClient(session: session))

        let times = try await client.liveTimes(category: "ICE", number: 507, day: "2026-10-13")

        let planned = try #require(JSONDecoding.parseISODate("2026-10-13T06:30:00.000Z"))
        let live = try #require(JSONDecoding.parseISODate("2026-10-13T08:27:00.000Z"))
        #expect(times.actual(eva: "8002549", planned: planned, side: .arrival) == live)
        // A side without a live time isn't made up.
        #expect(times.actual(eva: "8002549", planned: planned, side: .departure) == nil)
        #expect(times.actual(eva: "8000199", planned: planned, side: .arrival) == nil)
        // Another number is another train.
        await #expect(throws: (any Error).self) { try await client.liveTimes(category: "ICE", number: 508, day: "2026-10-13") }
    }
}

private final class ExpertRunProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let json = path.hasSuffix("journey/find")
            ? #"{"json":[{"journeyId":"20261013-aaaa","train":{"category":"ICE","journeyNumber":507}}]}"#
            : #"""
              {"json":{"stops":[
                {"stopPlace":{"evaNumber":"8000199"},"departure":{"scheduledTime":"2026-10-13T05:16:00.000Z","time":"2026-10-13T05:17:00.000Z"}},
                {"stopPlace":{"evaNumber":"8002549"},
                 "arrival":{"scheduledTime":"2026-10-13T06:30:00.000Z","time":"2026-10-13T08:27:00.000Z"},
                 "departure":{"scheduledTime":"2026-10-13T06:34:00.000Z"}}
              ]}}
              """#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
