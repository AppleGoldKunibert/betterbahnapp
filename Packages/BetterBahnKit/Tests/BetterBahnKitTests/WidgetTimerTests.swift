import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct WidgetTimerTests {
    private let end = Date(timeIntervalSince1970: 800_000_000)
    private func before(days: Double = 0, hours: Double = 0, minutes: Double = 0, seconds: Double = 0) -> Date {
        end.addingTimeInterval(-(days * 86400 + hours * 3600 + minutes * 60 + seconds))
    }

    @Test func showsDaysHoursAndMinutesBeyondTwelveHours() {
        #expect(WidgetTimer.longText(from: before(days: 2, hours: 3, minutes: 49), to: end) == "2d 3h 49m")
        #expect(WidgetTimer.longText(from: before(days: 1, minutes: 5), to: end) == "1d 0h 5m")
        #expect(WidgetTimer.longText(from: before(hours: 13, minutes: 5), to: end) == "13h 5m")
        // Part of a minute counts as a whole one, like the minute ticks.
        #expect(WidgetTimer.longText(from: before(days: 2, hours: 3, minutes: 48, seconds: 30), to: end) == "2d 3h 49m")
    }

    @Test func leavesTwelveHoursAndLessToTheRunningTimer() {
        #expect(WidgetTimer.longText(from: before(hours: 12), to: end) == nil)
        #expect(WidgetTimer.longText(from: before(hours: 2), to: end) == nil)
        #expect(WidgetTimer.longText(from: before(hours: 12, seconds: 1), to: end) == "12h 1m")
    }

    @Test func ticksEveryMinuteUntilTheRunningTimerTakesOver() {
        let now = before(hours: 12, minutes: 3, seconds: 20)
        let ticks = WidgetTimer.tickDates(to: end, after: now, until: now.addingTimeInterval(3600))
        #expect(ticks == [before(hours: 12, minutes: 3), before(hours: 12, minutes: 2), before(hours: 12, minutes: 1),
                          before(hours: 12)])
        #expect(ticks.map { WidgetTimer.longText(from: $0, to: end) } == ["12h 3m", "12h 2m", "12h 1m", nil])
    }

    @Test func ticksOnlyUpToTheGivenDate() {
        let now = before(days: 2, hours: 3, minutes: 49)
        let ticks = WidgetTimer.tickDates(to: end, after: now, until: now.addingTimeInterval(3600))
        #expect(ticks.count == 60)
        #expect(ticks.first == before(days: 2, hours: 3, minutes: 48))
        #expect(ticks.last == before(days: 2, hours: 2, minutes: 49))
        #expect(WidgetTimer.tickDates(to: end, after: before(hours: 5), until: end).isEmpty)
    }
}
