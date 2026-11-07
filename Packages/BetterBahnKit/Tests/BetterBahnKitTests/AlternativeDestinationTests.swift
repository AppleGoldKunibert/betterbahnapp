import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct AlternativeDestinationTests {
    private func time(_ minutes: Int) -> Date { Date(timeIntervalSince1970: 1_780_000_000).addingTimeInterval(TimeInterval(minutes * 60)) }

    private func leg(_ line: String, from: String, to: String, depart: Int, arrive: Int,
                     product: Product = .highSpeed) -> Leg {
        Leg(origin: station(from, from), destination: station(to, to),
            departure: TimeInfo(planned: time(depart), actual: nil),
            arrival: TimeInfo(planned: time(arrive), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: "trip-\(line)-\(depart)",
            line: Line(name: line, number: line, product: product, operatorName: nil),
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

    @Test func sameTrainServingBothShowsOncePerDestination() {
        // The RE calls at Süd first, then at Hbf.
        let toHbf = journey(leg("RE 3", from: "A", to: "Hbf", depart: 0, arrive: 20, product: .regionalExpress))
        let toSüd = journey(leg("RE 3", from: "A", to: "Süd", depart: 0, arrive: 7, product: .regionalExpress))

        #expect(AlternativeDestination.merging([toHbf], alternative: [toSüd]) == [toSüd, toHbf])
    }

    @Test func changingToReachTheOtherStationStaysToo() {
        let toHbf = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60))
        let toSüd = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60),
                            leg("S 1", from: "Hbf", to: "Süd", depart: 65, arrive: 75))

        #expect(AlternativeDestination.merging([toHbf], alternative: [toSüd]) == [toHbf, toSüd])
    }

    @Test func equalTimesShowTheDestinationItselfFirst() {
        let toHbf = journey(leg("ICE 1", from: "A", to: "Hbf", depart: 0, arrive: 60))
        let toSüd = journey(leg("ICE 1", from: "A", to: "Süd", depart: 0, arrive: 60))

        #expect(AlternativeDestination.merging([toHbf], alternative: [toSüd]) == [toHbf, toSüd])
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

    @Test func extraTrainsBeyondThePageDontEndItLater() {
        // The page to Hbf ends at 0:17; the RE at 0:24 is on its next page. An extra train (expert option, looked
        // up hours ahead) leaves at 0:27, but the list may only reach as far as the page itself.
        let main = AlternativeDestination.Results(
            journeys: [journey(leg("S 15", from: "A", to: "Hbf", depart: 17, arrive: 22, product: .suburban)),
                       journey(leg("ICE 1104", from: "A", to: "Hbf", depart: 27, arrive: 31))],
            hasLater: true, coveredUntil: time(17))
        let alternative = AlternativeDestination.Results(
            journeys: [journey(leg("RE 3", from: "A", to: "Süd", depart: 24, arrive: 44, product: .regionalExpress)),
                       journey(leg("RE 3", from: "A", to: "Süd", depart: 84, arrive: 104, product: .regionalExpress))],
            hasLater: true)

        let merged = AlternativeDestination.merging(main, alternative: alternative)

        #expect(merged.map { $0.transitLegs[0].line?.name } == ["S 15"])
        #expect(AlternativeDestination.loadsLater(main, alternative: alternative) == (main: true, alternative: false))
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

    @Test func aFailedListHoldsTheOtherBackNoLonger() {
        // The destination's later page failed: its cursor is still there, but it counts as having nothing more.
        let failed = AlternativeDestination.Results(journeys: [journey(leg("ICE 1", from: "A", to: "Hbf", depart: 30, arrive: 90))],
                                                    hasLater: false)
        let ahead = AlternativeDestination.Results(journeys: [journey(leg("RE 2", from: "A", to: "Süd", depart: 120, arrive: 200))],
                                                   hasLater: true)

        #expect(AlternativeDestination.loadsLater(failed, alternative: ahead) == (main: false, alternative: true))
        #expect(AlternativeDestination.merging(failed, alternative: ahead).count == 2)
    }

    @Test func alternativeMatchingStartOrDestinationIsNotSearched() {
        let a = station("A", "A"), hbf = station("Hbf", "Hbf"), süd = station("Süd", "Süd")

        #expect(AlternativeDestination.usable(süd, from: a, to: hbf) == süd)
        #expect(AlternativeDestination.usable(a, from: a, to: hbf) == nil)
        #expect(AlternativeDestination.usable(hbf, from: a, to: hbf) == nil)
        #expect(AlternativeDestination.usable(nil, from: a, to: hbf) == nil)
    }
}
