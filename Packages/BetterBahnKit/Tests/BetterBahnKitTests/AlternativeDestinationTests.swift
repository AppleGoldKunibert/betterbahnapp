import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct AlternativeDestinationTests {
    private func time(_ minutes: Int) -> Date { Date(timeIntervalSince1970: 1_780_000_000).addingTimeInterval(TimeInterval(minutes * 60)) }

    private func leg(_ line: String, from: String, to: String, depart: Int, arrive: Int,
                     product: Product = .highSpeed, delay: Int? = nil, cancelled: Bool = false) -> Leg {
        Leg(origin: station(from, from), destination: station(to, to),
            departure: TimeInfo(planned: time(depart), actual: delay.map { time(depart + $0) }),
            arrival: TimeInfo(planned: time(arrive), actual: delay.map { time(arrive + $0) }),
            departurePlatform: nil, arrivalPlatform: nil, tripId: "trip-\(line)-\(depart)",
            line: Line(name: line, number: line, product: product, operatorName: nil),
            direction: nil, isWalking: false, cancelled: cancelled,
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

    @Test func sameChangesButLaterArrivalIsDropped() {
        let viaB = journey(leg("ICE 1", from: "A", to: "B", depart: 0, arrive: 30),
                           leg("RE 5", from: "B", to: "Hbf", depart: 40, arrive: 70))
        let viaC = journey(leg("ICE 1", from: "A", to: "C", depart: 0, arrive: 45),
                           leg("RE 7", from: "C", to: "Süd", depart: 50, arrive: 80))

        #expect(AlternativeDestination.merging([viaB], alternative: [viaC]) == [viaB])
    }

    @Test func fewerChangesOrALaterDepartureStayBoth() {
        let direct = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 70))
        let faster = journey(leg("ICE 2", from: "A", to: "B", depart: 0, arrive: 30),
                             leg("ICE 4", from: "B", to: "Süd", depart: 35, arrive: 60))
        let leavesLater = journey(leg("ICE 6", from: "A", to: "Süd", depart: 10, arrive: 90))

        #expect(AlternativeDestination.merging([direct], alternative: [faster, leavesLater]).count == 3)
    }

    @Test func regionalConnectionStaysNextToAFasterICE() {
        let regional = journey(leg("RE 1", from: "A", to: "Hbf", depart: 0, arrive: 90, product: .regionalExpress))
        let ice = journey(leg("ICE 1", from: "A", to: "Süd", depart: 0, arrive: 60))

        #expect(AlternativeDestination.merging([regional], alternative: [ice]).count == 2)
        // The other way round the ICE isn't needed: the RE is there sooner without one.
        let slowICE = journey(leg("ICE 1", from: "A", to: "Süd", depart: 0, arrive: 95))
        #expect(AlternativeDestination.merging([regional], alternative: [slowICE]) == [regional])
    }

    @Test func cancelledOrDelayedConnectionReplacesNothing() {
        let toHbf = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 70))
        let cancelled = journey(leg("ICE 2", from: "A", to: "Süd", depart: 0, arrive: 60, cancelled: true))
        let late = journey(leg("ICE 3", from: "A", to: "Süd", depart: 0, arrive: 60, delay: 15))

        #expect(AlternativeDestination.merging([toHbf], alternative: [cancelled, late]).count == 3)
    }

    @Test func sortsByDepartureThenArrival() {
        let slowHbf = journey(leg("RE 1", from: "A", to: "Hbf", depart: 0, arrive: 80, product: .regionalExpress))
        let fastSüd = journey(leg("ICE 2", from: "A", to: "Süd", depart: 0, arrive: 60))
        let hbf = journey(leg("ICE 3", from: "A", to: "Hbf", depart: 30, arrive: 100))
        let süd = journey(leg("ICE 4", from: "A", to: "B", depart: 30, arrive: 50),
                          leg("ICE 6", from: "B", to: "Süd", depart: 60, arrive: 90))

        let merged = AlternativeDestination.merging([slowHbf, hbf], alternative: [süd, fastSüd])

        #expect(merged.map { $0.transitLegs[0].line?.name } == ["ICE 2", "RE 1", "ICE 4", "ICE 3"])
    }

    @Test func endsWhereTheShorterListEnds() {
        let main = [journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60)),
                    journey(leg("ICE 3", from: "A", to: "Hbf", depart: 60, arrive: 120)),
                    journey(leg("ICE 5", from: "A", to: "Hbf", depart: 120, arrive: 180))]
        let alternative = [journey(leg("RE 2", from: "A", to: "Süd", depart: 30, arrive: 100, product: .regionalExpress))]

        let waiting = AlternativeDestination.merging(.init(journeys: main, hasLater: true),
                                                     alternative: .init(journeys: alternative, hasLater: true))
        #expect(waiting.map { $0.transitLegs[0].line?.name } == ["ICE 1", "RE 2"])

        // Nothing more to the alternative: the rest of the destination's list shows.
        let complete = AlternativeDestination.merging(.init(journeys: main, hasLater: true),
                                                      alternative: .init(journeys: alternative, hasLater: false))
        #expect(complete.count == 4)
    }

    @Test func equalArrivalKeepsTheDestinationItself() {
        let toHbf = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60))
        let toSüd = journey(leg("ICE 1", from: "A", to: "Süd", depart: 0, arrive: 60))

        #expect(AlternativeDestination.merging([toHbf], alternative: [toSüd]) == [toHbf])
    }

    @Test func pagesOnlyTheListThatIsBehind() {
        let main = AlternativeDestination.Results(journeys: [journey(leg("ICE 1", from: "A", to: "Hbf", depart: 120, arrive: 180))],
                                                  hasLater: true)
        let behind = AlternativeDestination.Results(journeys: [journey(leg("RE 2", from: "A", to: "Süd", depart: 30, arrive: 100))],
                                                    hasLater: true)
        let level = AlternativeDestination.Results(journeys: [journey(leg("RE 2", from: "A", to: "Süd", depart: 120, arrive: 200))],
                                                   hasLater: true)

        #expect(AlternativeDestination.loadsLater(main, alternative: behind) == (main: false, alternative: true))
        #expect(AlternativeDestination.loadsLater(main, alternative: level) == (main: true, alternative: true))
        // Nothing more to the alternative: the destination pages on.
        let done = AlternativeDestination.Results(journeys: behind.journeys, hasLater: false)
        #expect(AlternativeDestination.loadsLater(main, alternative: done) == (main: true, alternative: false))
    }

    @Test func alternativeMatchingStartOrDestinationIsNotSearched() {
        let a = station("A", "A"), hbf = station("Hbf", "Hbf"), süd = station("Süd", "Süd")

        #expect(AlternativeDestination.usable(süd, from: a, to: hbf) == süd)
        #expect(AlternativeDestination.usable(a, from: a, to: hbf) == nil)
        #expect(AlternativeDestination.usable(hbf, from: a, to: hbf) == nil)
        #expect(AlternativeDestination.usable(nil, from: a, to: hbf) == nil)
    }
}
