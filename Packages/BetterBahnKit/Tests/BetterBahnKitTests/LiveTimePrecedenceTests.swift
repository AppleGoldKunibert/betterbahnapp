import Foundation
import Testing
@testable import BetterBahnKit

/// bahn.de's journey details overlay the times DB Timetables gave, but not a delay DB Timetables already
/// put on a stop: for RE 3 3354 (9 Oct 2026) bahn.de had +7 at Gesundbrunnen and ±0 at the end, where
/// DB Timetables (and DB Navigator) had +19 and +7.
struct LiveTimePrecedenceTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ minutes: TimeInterval) -> Date { now.addingTimeInterval(minutes * 60) }

    func stopover(_ id: String, _ minutes: TimeInterval, delay: TimeInterval?) -> Stopover {
        let time = TimeInfo(planned: at(minutes), actual: delay.map { at(minutes + $0) })
        return Stopover(station: station(id, id, source: .transitous), arrival: time, departure: time,
                        arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    func bahnDeStop(_ id: String, _ minutes: TimeInterval, delay: TimeInterval) -> JourneyStop {
        let time = TimeInfo(planned: at(minutes), actual: at(minutes + delay))
        return JourneyStop(evaNumber: id, name: id, arrival: time, departure: time)
    }

    func delays(_ stopovers: [Stopover]) -> [Int?] {
        stopovers.map { $0.departure?.delayMinutes }
    }

    @Test func aDelayFromDBTimetablesStaysWhenBahnDeDiffers() {
        let timetables = [stopover("gesundbrunnen", 0, delay: 19), stopover("bernau", 12, delay: 19), stopover("schwedt", 83, delay: 7)]
        let bahnDe = [bahnDeStop("gesundbrunnen", 0, delay: 7), bahnDeStop("bernau", 12, delay: 7), bahnDeStop("schwedt", 83, delay: 0)]

        #expect(delays(BahnDeClient.applyingLiveTimes(from: bahnDe, to: timetables, keepingDelays: true)) == [19, 19, 7])
        // Without DB Timetables' answer bahn.de's times win, as before.
        #expect(delays(BahnDeClient.applyingLiveTimes(from: bahnDe, to: timetables)) == [7, 7, 0])
    }

    @Test func bahnDeStillFillsWhatIsMissingOrOnTime() {
        // RJ 383: no delay known at Bad Schandau (nothing, or "on time"), bahn.de had +57.
        let known = [stopover("dresden", 0, delay: 59), stopover("badschandau", 30, delay: nil), stopover("decin", 45, delay: 0)]
        let bahnDe = [bahnDeStop("dresden", 0, delay: 57), bahnDeStop("badschandau", 30, delay: 57), bahnDeStop("decin", 45, delay: 55)]

        #expect(delays(BahnDeClient.applyingLiveTimes(from: bahnDe, to: known, keepingDelays: true)) == [59, 57, 55])
    }

    @Test func theLegsEndsFollowTheSameRule() {
        let origin = station("gesundbrunnen", "gesundbrunnen", source: .transitous)
        let destination = station("schwedt", "schwedt", source: .transitous)
        let leg = Leg(origin: origin, destination: destination,
                      departure: TimeInfo(planned: at(0), actual: at(19)), arrival: TimeInfo(planned: at(83), actual: at(90)),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "3354",
                      line: Line(name: "RE 3", number: nil, product: .regionalExpress, operatorName: nil), direction: nil,
                      isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        let bahnDe = [bahnDeStop("gesundbrunnen", 0, delay: 7), bahnDeStop("schwedt", 83, delay: 0)]

        let kept = BahnDeClient.applyingLiveTimes(from: bahnDe, to: leg, keepingDelays: true)
        #expect(kept.departure.delayMinutes == 19)
        #expect(kept.arrival.delayMinutes == 7)

        let replaced = BahnDeClient.applyingLiveTimes(from: bahnDe, to: leg)
        #expect(replaced.departure.delayMinutes == 7)
        #expect(replaced.arrival.delayMinutes == 0)
    }

    @Test func replacesOnlyAnEmptyOrOnTimeValueWhenKeepingDelays() {
        let planned = at(0)
        #expect(BahnDeClient.replaces(nil, with: at(5), keepingDelays: true))
        #expect(BahnDeClient.replaces(TimeInfo(planned: planned, actual: nil), with: at(5), keepingDelays: true))
        #expect(BahnDeClient.replaces(TimeInfo(planned: planned, actual: planned), with: at(5), keepingDelays: true))
        #expect(!BahnDeClient.replaces(TimeInfo(planned: planned, actual: at(2)), with: at(5), keepingDelays: true))
        #expect(BahnDeClient.replaces(TimeInfo(planned: planned, actual: at(2)), with: at(5), keepingDelays: false))
    }
}
