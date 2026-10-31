import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct AlternativeDestinationTests {
    private func time(_ minutes: Int) -> Date { Date(timeIntervalSince1970: 1_780_000_000).addingTimeInterval(TimeInterval(minutes * 60)) }

    private func leg(_ line: String, from: String, to: String, depart: Int, arrive: Int) -> Leg {
        Leg(origin: station(from, from), destination: station(to, to),
            departure: TimeInfo(planned: time(depart), actual: nil),
            arrival: TimeInfo(planned: time(arrive), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: "trip-\(line)-\(depart)",
            line: Line(name: line, number: line, product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false,
            stopovers: [], remarks: [], source: .bahnDe)
    }

    private func journey(_ legs: Leg...) -> Journey { Journey(legs: legs, source: .bahnDe) }

    @Test func mergesBothListsByDeparture() {
        let main = [journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60)),
                    journey(leg("ICE 3", from: "A", to: "Hbf", depart: 60, arrive: 120))]
        let alternative = [journey(leg("RE 2", from: "A", to: "Süd", depart: 30, arrive: 100))]

        let merged = AlternativeDestination.merging(main, alternative: alternative)

        #expect(merged.map { $0.transitLegs[0].line?.name } == ["ICE 1", "RE 2", "ICE 3"])
    }

    @Test func sameTrainServingBothKeepsTheEarlierArrival() {
        // The ICE calls at Süd first, then at Hbf.
        let toHbf = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 70))
        let toSüd = journey(leg("ICE 1", from: "A", to: "Süd", depart: 0, arrive: 60))

        let merged = AlternativeDestination.merging([toHbf], alternative: [toSüd])

        #expect(merged == [toSüd])
    }

    @Test func changingJustToReachTheOtherStationIsDropped() {
        let toHbf = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60))
        let toSüd = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60),
                            leg("S 1", from: "Hbf", to: "Süd", depart: 65, arrive: 75))

        #expect(AlternativeDestination.merging([toHbf], alternative: [toSüd]) == [toHbf])
        #expect(AlternativeDestination.merging([toSüd], alternative: [toHbf]) == [toHbf])
    }

    @Test func differentChangesStayBoth() {
        let viaB = journey(leg("ICE 1", from: "A", to: "B", depart: 0, arrive: 30),
                           leg("RE 5", from: "B", to: "Hbf", depart: 40, arrive: 70))
        let viaC = journey(leg("ICE 1", from: "A", to: "C", depart: 0, arrive: 45),
                           leg("RE 7", from: "C", to: "Süd", depart: 50, arrive: 80))

        #expect(AlternativeDestination.merging([viaB], alternative: [viaC]).count == 2)
    }

    @Test func equalArrivalKeepsTheDestinationItself() {
        let toHbf = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60))
        let toSüd = journey(leg("ICE 1", from: "A", to: "Süd", depart: 0, arrive: 60))

        #expect(AlternativeDestination.merging([toHbf], alternative: [toSüd]) == [toHbf])
    }
}
