import Foundation
import Testing
@testable import BetterBahnKit

/// The departure board shows what bahn.de and Transitous say, and they show a train that runs early as on
/// time. `applyingRealtime(to:at:)` lays DB OpenBoards' own data over it, as the stop lists do.
struct BoardRealtimeTests {
    let berlin = station("8011160", "Berlin Hbf", source: .bahnDe)
    // 2027-01-15 08:00 UTC == 09:00 Europe/Berlin (CET).
    let planned = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { planned.addingTimeInterval(-10 * 60) }

    func entry(_ name: String, _ number: String, actual: TimeInterval? = nil, product: Product = .highSpeed,
               platform: PlatformInfo = PlatformInfo(planned: "5", actual: nil)) -> BoardEntry {
        BoardEntry(kind: .departures, tripId: name + number, station: berlin,
                   line: Line(name: "\(name) \(number)", number: number, product: product, operatorName: nil),
                   otherEnd: nil, time: TimeInfo(planned: planned, actual: actual.map { planned.addingTimeInterval($0 * 60) }),
                   platform: platform, cancelled: false, terminatesOrOriginatesHere: nil, remarks: [], source: .transitous)
    }

    func timetables(failing: Bool = false) -> (OpenBoardsClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [failing ? BoardRealtimeFailingProtocol.self : BoardRealtimeProtocol.self]
        let session = URLSession(configuration: config)
        return (OpenBoardsClient(http: HTTPClient(session: session)), session)
    }

    @Test func dbOpenBoardsWinsOverBahnDeAndTransitous() async {
        let (client, session) = timetables()
        defer { session.invalidateAndCancel() }
        let board = [
            entry("ICE", "1162", actual: 0),          // bahn.de: ±0, DB: 10 minutes early
            entry("ICE", "555", actual: 7),           // bahn.de: +7, DB: +19
            entry("RE", "3121", product: .regional),  // DB: cancelled
            entry("IC", "2000", platform: PlatformInfo(planned: "5", actual: nil)), // DB lists no change: on time
            entry("ICE", "999", actual: 3),           // not on DB's board: stays as it was
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

    @Test func withoutABoardTheBoardStaysAsItWas() async {
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

private class BoardRealtimeProtocol: OpenBoardsProtocol, @unchecked Sendable {
    class var status: Int { 200 }

    override class func answer(_ side: BoardSide, evas: [String], url: URL) -> (Int, String) {
        guard status == 200 else { return (status, "") }
        guard side == .departure, evas.contains("8011160") else { return super.answer(side, evas: evas, url: url) }
        func item(_ category: String, _ number: Int, live: String? = nil, platform: String? = nil, cancelled: Bool = false) -> [String: Any] {
            OpenBoardsJSON.item(.departure, category, number, at: "2027-01-15T09:00:00+01:00", live: live, platformSchedule: "5",
                                platform: platform, cancelled: cancelled)
        }
        return (200, OpenBoardsJSON.board(side, [
            item("ICE", 1162, live: "2027-01-15T08:50:00+01:00"),
            item("ICE", 555, live: "2027-01-15T09:19:00+01:00", platform: "9"),
            item("RE", 3121, cancelled: true),
            item("IC", 2000),
        ]))
    }
}

/// Same board, but DB's answer is an error.
private final class BoardRealtimeFailingProtocol: BoardRealtimeProtocol, @unchecked Sendable {
    override class var status: Int { 503 }
}
