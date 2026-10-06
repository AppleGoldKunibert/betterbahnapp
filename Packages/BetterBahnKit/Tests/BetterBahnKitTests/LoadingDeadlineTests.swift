import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

@Suite struct LoadingDeadlineTests {
    /// Live data in time: only the live result is shown, never the timetable first.
    @Test func fastWorkShowsOnlyItsResult() async {
        let shownEarly = Mutex(0)
        let result = await LoadingDeadline.run({ "live" }, showingAfter: .seconds(5)) {
            shownEarly.withLock { $0 += 1 }
        }
        #expect(result == "live")
        #expect(shownEarly.withLock { $0 } == 0)
    }

    /// Live data too slow: the timetable shows once meanwhile, and the live result still comes last.
    @Test func slowWorkShowsWhatIsThereMeanwhile() async {
        let events = Mutex<[String]>([])
        let result = await LoadingDeadline.run({
            // Stays slow until the timetable has shown, so a busy test runner can't let it win the race.
            let giveUp = ContinuousClock.now + .seconds(10)
            while !events.withLock({ $0.contains("timetable") }), ContinuousClock.now < giveUp {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return "live"
        }, showingAfter: .milliseconds(20)) {
            events.withLock { $0.append("timetable") }
        }
        events.withLock { $0.append(result) }
        #expect(events.withLock { $0 } == ["timetable", "live"])
    }
}
