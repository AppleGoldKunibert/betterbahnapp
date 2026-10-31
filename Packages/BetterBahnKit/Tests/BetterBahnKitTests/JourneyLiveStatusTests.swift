import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct JourneyLiveStatusTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func leg(_ line: String, _ from: String, _ to: String, dep: Double, arr: Double, arrDelay: Double = 0,
             walking: Bool = false) -> Leg {
        Leg(origin: station(from, from), destination: station(to, to),
            departure: TimeInfo(planned: base.addingTimeInterval(dep * 60), actual: nil),
            arrival: TimeInfo(planned: base.addingTimeInterval(arr * 60), actual: base.addingTimeInterval((arr + arrDelay) * 60)),
            departurePlatform: nil, arrivalPlatform: nil, tripId: walking ? nil : line,
            line: walking ? nil : Line(name: line, number: nil, product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: walking, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    var journey: Journey {
        Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60, arrDelay: 4),
                       leg("", "B", "B", dep: 64, arr: 66, walking: true),
                       leg("ICE 2", "B", "C", dep: 70, arr: 120),
                       leg("IC 3", "C", "D", dep: 130, arr: 180)], source: .bahnDe)
    }

    func at(_ minutes: Double) -> JourneyLiveStatus? {
        JourneyLiveStatus.at(base.addingTimeInterval(minutes * 60), of: journey)
    }

    @Test func beforeTheStartShowsTheDepartureAndTheFirstTransfer() throws {
        let status = try #require(at(-10))
        #expect(status.step == .departure(journey.legs[0]))
        #expect(status.upcomingLegs.compactMap(\.line?.name) == ["ICE 1", "ICE 2", "IC 3"])
        // The first train runs 4 minutes late, leaving 6 of the planned 10 minutes; walks don't count.
        #expect(status.nextTransfer?.next.line?.name == "ICE 2")
        #expect(status.nextTransfer?.minutes == 6)
    }

    @Test func onATrainItComesFirstAndTheRidesBehindDropOut() throws {
        let status = try #require(at(80))
        #expect(status.step == .riding(journey.legs[2]))
        #expect(status.upcomingLegs.compactMap(\.line?.name) == ["ICE 2", "IC 3"])
        #expect(status.nextTransfer?.minutes == 10)
    }

    @Test func betweenTrainsItIsATransfer() throws {
        let status = try #require(at(66))
        #expect(status.step == .transfer(previous: journey.legs[0], next: journey.legs[2]))
        #expect(status.upcomingLegs.first?.line?.name == "ICE 2")
    }

    @Test func aMissedConnectionHasNegativeMinutes() throws {
        let late = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60, arrDelay: 15),
                                  leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .bahnDe)
        let status = try #require(JourneyLiveStatus.at(base, of: late))
        #expect(status.nextTransfer?.minutes == -5)
    }

    @Test func endsOnArrival() {
        #expect(at(181) == nil)
        #expect(at(179)?.nextTransfer == nil)
    }
}
