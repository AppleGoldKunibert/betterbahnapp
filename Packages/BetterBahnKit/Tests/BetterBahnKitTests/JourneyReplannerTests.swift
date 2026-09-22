import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct JourneyReplanTests {
    private func time(_ minutes: Int) -> Date { Date(timeIntervalSince1970: 0).addingTimeInterval(TimeInterval(minutes * 60)) }

    private func leg(_ line: String?, from: String, to: String, depart: Int, arrive: Int,
                     tripId: String? = nil) -> Leg {
        Leg(origin: station(from, from), destination: station(to, to),
            departure: TimeInfo(planned: time(depart), actual: nil),
            arrival: TimeInfo(planned: time(arrive), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: tripId ?? line.map { "trip-\($0)" },
            line: line.map { Line(name: $0, number: nil, product: .regionalExpress, operatorName: nil) },
            direction: nil, isWalking: line == nil, cancelled: false,
            stopovers: [], remarks: [], source: .bahnDe)
    }

    @Test func rebuildKeepsEarlierLegsAndAppendsContinuation() {
        let first = leg("RE 1", from: "A", to: "B", depart: 0, arrive: 30)
        let second = leg("RE 2", from: "B", to: "C", depart: 40, arrive: 90)
        let journey = Journey(legs: [first, second], source: .bahnDe)
        // Get off the second train in X instead of C, then carry on from there.
        let shortened = leg("RE 2", from: "B", to: "X", depart: 40, arrive: 60)
        let continuation = Journey(legs: [leg("RB 9", from: "X", to: "C", depart: 70, arrive: 100)], source: .bahnDe)

        let rebuilt = JourneyReplanner.rebuild(journey, replacingLegAt: 1, with: shortened, continuation: continuation)

        #expect(rebuilt.legs.count == 3)
        #expect(rebuilt.legs[0] == first)
        #expect(rebuilt.legs[1].destination.name == "X")
        #expect(rebuilt.legs[2].line?.name == "RB 9")
        #expect(rebuilt.arrival?.planned == time(100))
    }

    @Test func rebuildWithoutContinuationEndsAtTheNewExit() {
        let journey = Journey(legs: [leg("RE 1", from: "A", to: "C", depart: 0, arrive: 60)], source: .bahnDe)
        let shortened = leg("RE 1", from: "A", to: "B", depart: 0, arrive: 40)

        let rebuilt = JourneyReplanner.rebuild(journey, replacingLegAt: 0, with: shortened, continuation: nil)

        #expect(rebuilt.legs.count == 1)
        #expect(rebuilt.legs[0].destination.name == "B")
        #expect(rebuilt.arrival?.planned == time(40))
    }

    /// Staying on the same train must not show that train twice.
    @Test func rebuildMergesAContinuationOnTheSameTrip() {
        let ride = leg("ICE 5", from: "A", to: "C", depart: 0, arrive: 120, tripId: "ice5")
        let journey = Journey(legs: [ride], source: .bahnDe)
        let shortened = leg("ICE 5", from: "A", to: "B", depart: 0, arrive: 60, tripId: "ice5")
        let sameTrain = Journey(legs: [leg("ICE 5", from: "B", to: "D", depart: 60, arrive: 150, tripId: "ice5")],
                                source: .bahnDe)

        let rebuilt = JourneyReplanner.rebuild(journey, replacingLegAt: 0, with: shortened, continuation: sameTrain)

        #expect(rebuilt.legs.count == 1)
        #expect(rebuilt.legs[0].origin.name == "A")
        #expect(rebuilt.legs[0].destination.name == "D")
        #expect(rebuilt.arrival?.planned == time(150))
    }

    @Test func legEndingAtAnEarlierStopIsBuiltFromTheTripsStops() throws {
        let stops = ["A", "B", "C"].enumerated().map { index, name in
            Stopover(station: station(name, name),
                     arrival: TimeInfo(planned: time(index * 30), actual: nil),
                     departure: TimeInfo(planned: time(index * 30 + 2), actual: nil),
                     arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let trip = Trip(id: "t1", line: Line(name: "RE 1", number: "1", product: .regionalExpress, operatorName: nil),
                        direction: "C", stopovers: stops, cancelled: false, remarks: [], source: .bahnDe)

        let shortened = try #require(trip.leg(from: station("A", "A"), to: station("B", "B")))

        #expect(shortened.destination.name == "B")
        #expect(shortened.arrival.planned == time(30))
        #expect(shortened.stopovers.count == 2)
    }
}
