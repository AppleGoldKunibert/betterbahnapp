import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct PlatformChangeTests {
    let frankfurt = station("8000105", "Frankfurt (Main) Hbf")
    let fulda = station("8000115", "Fulda")
    let berlin = station("8011160", "Berlin Hbf")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func time(_ minutes: Double) -> TimeInfo { TimeInfo(planned: now.addingTimeInterval(minutes * 60), actual: nil) }

    func leg(_ name: String, _ from: Station, _ to: Station, dep: Double, arr: Double,
             depPlatform: String?, arrPlatform: String?) -> Leg {
        Leg(origin: from, destination: to, departure: time(dep), arrival: time(arr),
            departurePlatform: PlatformInfo(planned: depPlatform, actual: nil),
            arrivalPlatform: PlatformInfo(planned: arrPlatform, actual: nil),
            tripId: "trip-\(name)", line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    /// ICE 578 Frankfurt → Fulda, change to ICE 1000 Fulda → Berlin with 6 minutes.
    func journey(start: String = "7", fuldaArrival: String = "3", fuldaDeparture: String = "4", startIn: Double = 30) -> Journey {
        Journey(legs: [
            leg("ICE 578", frankfurt, fulda, dep: startIn, arr: startIn + 54, depPlatform: "7", arrPlatform: "3"),
            leg("ICE 1000", fulda, berlin, dep: startIn + 60, arr: startIn + 240, depPlatform: "4", arrPlatform: "12"),
        ].enumerated().map { index, leg in
            var leg = leg
            if index == 0 {
                leg.departurePlatform?.actual = start
                leg.arrivalPlatform?.actual = fuldaArrival
            } else {
                leg.departurePlatform?.actual = fuldaDeparture
            }
            return leg
        }, source: .bahnDe)
    }

    @Test func departureChangeIsReported() throws {
        let changes = journey(start: "9").platformChanges(since: journey(), now: now)
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.kind == .departure)
        #expect(change.oldPlatform == "7")
        #expect(change.newPlatform == "9")
        #expect(change.message == "Abfahrt Frankfurt (Main) Hbf jetzt von Gleis 9 (statt 7)")
        #expect(change.title == "ICE 578: Gleiswechsel")
    }

    @Test func transferPlatformsAreChecked() {
        let changes = journey(fuldaArrival: "5", fuldaDeparture: "6").platformChanges(since: journey(), now: now)
        #expect(changes.map(\.kind) == [.arrival, .departure])
        #expect(changes.map(\.transferMinutes) == [6, 6])
        #expect(changes.last?.message == "Abfahrt Fulda jetzt von Gleis 6 (statt 4)\nUmstieg: 6 Min.")
    }

    @Test func sectorAndSpellingChangesAreIgnored() {
        #expect(journey(start: "7 A-C").platformChanges(since: journey(), now: now).isEmpty)
        #expect(journey(start: " 7").platformChanges(since: journey(), now: now).isEmpty)
        // A bus bay letter some feeds give trains (#30) can't be compared with a track.
        #expect(journey(start: "F").platformChanges(since: journey(), now: now).isEmpty)
    }

    @Test func switchingBackGetsItsOwnID() throws {
        let changed = journey(start: "9")
        let away = try #require(changed.platformChanges(since: journey(), now: now).first)
        let back = try #require(journey().platformChanges(since: changed, now: now).first)
        #expect(away.id != back.id)
        #expect(back.newPlatform == "7")
        // Refreshing again without a change reports nothing.
        #expect(changed.platformChanges(since: changed, now: now).isEmpty)
    }

    @Test func onlyWithinTheNextTwoHours() {
        let later = journey(start: "9", startIn: 3 * 60)
        #expect(later.platformChanges(since: journey(startIn: 3 * 60), now: now).isEmpty)
    }

    @Test func tightTransferIsUrgent() {
        let change = PlatformChange(kind: .departure, line: "ICE 1", station: "Fulda", oldPlatform: "4", newPlatform: "6",
                                    transferMinutes: 3, legID: "x")
        #expect(change.isTight)
    }

    #if canImport(ActivityKit) && os(iOS)
    @Test func liveActivityShowsReplacedPlatform() {
        #expect(TripActivityAttributes.ContentState.replacedPlatform(PlatformInfo(planned: "7", actual: "9")) == "7")
        #expect(TripActivityAttributes.ContentState.replacedPlatform(PlatformInfo(planned: "7", actual: "7 A-C")) == nil)
    }
    #endif
}
