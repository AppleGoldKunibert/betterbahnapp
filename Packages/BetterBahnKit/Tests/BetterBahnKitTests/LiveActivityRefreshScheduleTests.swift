import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct LiveActivityRefreshScheduleTests {
    private func time(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 0).addingTimeInterval(minutes * 60) }

    private func leg(_ line: String?, depart: Double, arrive: Double) -> Leg {
        Leg(origin: station("A", "A"), destination: station("B", "B"),
            departure: TimeInfo(planned: time(depart), actual: nil),
            arrival: TimeInfo(planned: time(arrive), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: line.map { "trip-\($0)" },
            line: line.map { Line(name: $0, number: nil, product: .regionalExpress, operatorName: nil) },
            direction: nil, isWalking: line == nil, cancelled: false,
            stopovers: [], remarks: [], source: .bahnDe)
    }

    /// RE 1 from 0 to 30, a 5-minute walk, RE 2 from 40 to 90.
    private var journey: Journey {
        Journey(legs: [leg("RE 1", depart: 0, arrive: 30), leg(nil, depart: 31, arrive: 36), leg("RE 2", depart: 40, arrive: 90)],
                source: .bahnDe)
    }

    private func next(at minutes: Double) -> Date {
        LiveActivityRefreshSchedule.nextRefresh(for: journey, after: time(minutes))
    }

    @Test func refreshesEveryTwoMinutesWhileWaitingOrRiding() {
        #expect(next(at: -10) == time(-8))
        #expect(next(at: 10) == time(12))
        #expect(next(at: 50) == time(52))
    }

    @Test func checksOneMinuteBeforeAtAndAfterArrival() {
        #expect(next(at: 28) == time(29))
        #expect(next(at: 29) == time(30))
        #expect(next(at: 30) == time(31))
        #expect(next(at: 88.5) == time(89))
    }

    @Test func refreshesEveryMinuteDuringTransfer() {
        #expect(next(at: 31) == time(32))
        #expect(next(at: 38) == time(39))
        // The next train has left: back to riding.
        #expect(next(at: 40) == time(42))
    }

    @Test func refreshesRegularlyAfterTheLastArrival() {
        #expect(next(at: 91) == time(93))
    }
}
