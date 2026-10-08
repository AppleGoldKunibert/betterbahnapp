import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// The reports a `TrainSightings` sent, in order.
private final class Reports: Sendable {
    private let reports = Mutex<[[String]]>([])
    func append(_ ids: [String]) { reports.withLock { $0.append(ids) } }
    func withLock<T>(_ body: ([[String]]) -> T) -> T { reports.withLock { body($0) } }
}

@Suite struct TrainSightingsTests {
    /// A sightings collector whose reports land in `sent` instead of the Worker.
    private func collector(delay: Duration = .seconds(3600)) -> (TrainSightings, Reports) {
        let sent = Reports()
        let sightings = TrainSightings(delay: delay) { ids in sent.append(ids) }
        return (sightings, sent)
    }

    @Test func reportsNothingWhileSwitchedOff() async {
        let (sightings, sent) = collector()
        await sightings.record(["a"])
        await sightings.flush()
        #expect(sent.withLock { $0 }.isEmpty)
    }

    @Test func reportsEachTrainOnceInBatchesOfAHundred() async {
        let (sightings, sent) = collector()
        await sightings.setEnabled(true)
        let ids = (0..<150).map { "2|#VN#1#ZE#\($0)#" }
        await sightings.record(ids + ids.prefix(10))
        await sightings.flush()
        #expect(sent.withLock { $0.map(\.count) } == [100, 50])

        // A board refreshed a minute later doesn't report its trains again.
        await sightings.record(Array(ids.prefix(5)) + ["new"])
        await sightings.flush()
        #expect(sent.withLock { $0.last } == ["new"])
    }

    @Test func switchingOffDropsWhatWasCollected() async {
        let (sightings, sent) = collector()
        await sightings.setEnabled(true)
        await sightings.record(["a", "b"])
        await sightings.setEnabled(false)
        await sightings.setEnabled(true)
        await sightings.flush()
        #expect(sent.withLock { $0 }.isEmpty)
    }

    @Test func sendsSoonAfterTheFirstNewTrain() async throws {
        let (sightings, sent) = collector(delay: .milliseconds(20))
        await sightings.setEnabled(true)
        await sightings.record(["a"])
        await sightings.record(["b"])
        for _ in 0..<100 where sent.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sent.withLock { $0 } == [["a", "b"]])
    }
}
