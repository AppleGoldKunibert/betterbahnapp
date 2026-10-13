import Foundation
import Testing
@testable import BetterBahnKit

/// The departure board shows what bahn.de and Transitous say, and they show a train that runs early as on
/// time. `applyingRealtime(to:at:)` lays DB Timetables' own data over it, as the stop lists do.
struct BoardRealtimeTests {
    let berlin = station("8011160", "Berlin Hbf", source: .bahnDe)
    // 2027-01-15 08:00 UTC == 09:00 Europe/Berlin (CET) -> IRIS "2701150900".
    let planned = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { planned.addingTimeInterval(-10 * 60) }

    func entry(_ name: String, _ number: String, actual: TimeInterval? = nil, product: Product = .highSpeed,
               platform: PlatformInfo = PlatformInfo(planned: "5", actual: nil)) -> BoardEntry {
        BoardEntry(kind: .departures, tripId: name + number, station: berlin,
                   line: Line(name: "\(name) \(number)", number: number, product: product, operatorName: nil),
                   otherEnd: nil, time: TimeInfo(planned: planned, actual: actual.map { planned.addingTimeInterval($0 * 60) }),
                   platform: platform, cancelled: false, terminatesOrOriginatesHere: nil, remarks: [], source: .transitous)
    }

    func timetables(failing: Bool = false) -> (TimetablesClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [failing ? BoardRealtimeFailingProtocol.self : BoardRealtimeProtocol.self]
        let session = URLSession(configuration: config)
        return (TimetablesClient(http: HTTPClient(session: session)), session)
    }

    @Test func dbTimetablesWinsOverBahnDeAndTransitous() async {
        let (client, session) = timetables()
        defer { session.invalidateAndCancel() }
        let board = [
            entry("ICE", "1162", actual: 0),          // bahn.de: ±0, DB: 10 minutes early
            entry("ICE", "555", actual: 7),           // bahn.de: +7, DB: +19
            entry("RE", "3121", product: .regional),  // DB: cancelled
            entry("IC", "2000", platform: PlatformInfo(planned: "5", actual: nil)), // DB lists no change: on time
            entry("ICE", "999", actual: 3),           // not in DB's plan: stays as it was
        ]

        let live = await client.applyingRealtime(to: board, at: berlin, now: now)

        #expect(live[0].time.delayMinutes == -10)
        #expect(live[1].time.delayMinutes == 19)
        #expect(live[2].cancelled)
        #expect(live[3].time.delayMinutes == 0)
        #expect(!live[3].cancelled)
        #expect(live[4] == board[4])
    }

    @Test func aPlatformChangeIsOverlaid() async {
        let (client, session) = timetables()
        defer { session.invalidateAndCancel() }

        let live = await client.applyingRealtime(to: [entry("ICE", "555", actual: 7)], at: berlin, now: now)

        #expect(live[0].platform == PlatformInfo(planned: "5", actual: "9"))
    }

    @Test func withoutFchgTheBoardStaysAsItWas() async {
        let (client, session) = timetables(failing: true)
        defer { session.invalidateAndCancel() }
        let board = [entry("ICE", "1162", actual: 0), entry("ICE", "555", actual: 7)]

        // The bare schedule would read as "on time, running" and wipe out what the other providers know.
        #expect(await client.applyingRealtime(to: board, at: berlin, now: now) == board)
    }

    @Test func aTrainThatRanLongAgoIsNotAskedAbout() async {
        let (client, session) = timetables()
        defer { session.invalidateAndCancel() }
        let board = [entry("ICE", "1162", actual: 0)]

        // DB's change list drops a train a few hours after it ran; the schedule alone would invent "+0".
        let later = planned.addingTimeInterval(5 * 3600)
        #expect(await client.applyingRealtime(to: board, at: berlin, now: later) == board)
    }
}

private class BoardRealtimeProtocol: URLProtocol, @unchecked Sendable {
    class var fchgStatus: Int { 200 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200
        let body: Data
        if path.contains("plan/") {
            body = Data("""
            <timetable station='Berlin Hbf'>
              <s id="a"><tl c="ICE" n="1162"/><dp pt="2701150900" pp="5"/></s>
              <s id="b"><tl c="ICE" n="555"/><dp pt="2701150900" pp="5"/></s>
              <s id="c"><tl c="RE" n="3121"/><dp pt="2701150900" pp="5"/></s>
              <s id="d"><tl c="IC" n="2000"/><dp pt="2701150900" pp="5"/></s>
            </timetable>
            """.utf8)
        } else if path.contains("fchg/") {
            status = type(of: self).fchgStatus
            body = Data("""
            <timetable station='Berlin Hbf'>
              <s id="a"><dp ct="2701150850"/></s>
              <s id="b"><dp ct="2701150919" cp="9"/></s>
              <s id="c"><dp cs="c"/></s>
            </timetable>
            """.utf8)
        } else {
            body = Data("<timetable></timetable>".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Same schedule, but `fchg` is down.
private final class BoardRealtimeFailingProtocol: BoardRealtimeProtocol {
    override class var fchgStatus: Int { 503 }
}
