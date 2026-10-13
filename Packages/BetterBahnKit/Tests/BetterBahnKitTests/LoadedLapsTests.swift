import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct LoadedLapsTests {
    let key = LoadedLaps.key(tripId: "s42", station: station("t:gesundbrunnen", "Gesundbrunnen", source: .transitous),
                             near: Date(timeIntervalSince1970: 1_791_540_000))
    let now = Date(timeIntervalSince1970: 1_791_550_000)

    func laps(_ extra: LoadedLaps.Extra, savedTrips: Set<String> = [], at time: Date? = nil) -> LoadedLaps {
        var laps = LoadedLaps()
        laps.store(extra, for: key, tripId: "s42", now: time ?? now, isSaved: { savedTrips.contains($0) })
        return laps
    }

    @Test func remembersTheLoadedLapsWhileItIsLookedAt() {
        var laps = laps(.init(before: 1, after: 2))
        #expect(laps.open(key, isSaved: false, now: now.addingTimeInterval(14 * 60)) == .init(before: 1, after: 2))
        // Opening counted as looking at it: 14 more minutes on, still there.
        #expect(laps.open(key, isSaved: false, now: now.addingTimeInterval(28 * 60)) == .init(before: 1, after: 2))
    }

    @Test func forgetsThemAfterFifteenMinutesUnlessSaved() {
        var unsaved = laps(.init(after: 1))
        #expect(unsaved.open(key, isSaved: false, now: now.addingTimeInterval(15 * 60)) == .init())
        // Gone for good, also if it is opened again within the time.
        #expect(unsaved.open(key, isSaved: false, now: now.addingTimeInterval(15 * 60 + 1)) == .init())

        var saved = laps(.init(after: 1))
        #expect(saved.open(key, isSaved: true, now: now.addingTimeInterval(3 * 24 * 3600)) == .init(after: 1))
    }

    @Test func closingTheTripExtendsTheTime() {
        var laps = laps(.init(before: 1))
        laps.viewed(key, now: now.addingTimeInterval(10 * 60))
        #expect(laps.open(key, isSaved: false, now: now.addingTimeInterval(24 * 60)) == .init(before: 1))
    }

    @Test func otherStopOfTheSameTripHasItsOwnLaps() {
        var laps = laps(.init(after: 3))
        let other = LoadedLaps.key(tripId: "s42", station: station("t:wedding", "Wedding", source: .transitous),
                                   near: Date(timeIntervalSince1970: 1_791_540_000))
        #expect(laps.open(other, isSaved: false, now: now) == .init())
    }

    @Test func storingDropsWhatExpiredAndKeepsSavedTrips() {
        var laps = LoadedLaps()
        laps.store(.init(after: 1), for: "old", tripId: "old", now: now) { _ in false }
        laps.store(.init(after: 1), for: "kept", tripId: "kept", now: now) { $0 == "kept" }
        laps.store(.init(after: 1), for: "new", tripId: "new", now: now.addingTimeInterval(3600)) { $0 == "kept" }

        #expect(laps.open("old", isSaved: false, now: now.addingTimeInterval(3600)) == .init())
        #expect(laps.open("kept", isSaved: true, now: now.addingTimeInterval(3600)) == .init(after: 1))
        #expect(laps.open("new", isSaved: false, now: now.addingTimeInterval(3600)) == .init(after: 1))
    }

    @Test func survivesBeingSavedToDisk() throws {
        let laps = laps(.init(before: 2, after: 1))
        var restored = try JSONDecoder().decode(LoadedLaps.self, from: JSONEncoder().encode(laps))
        #expect(restored.open(key, isSaved: false, now: now) == .init(before: 2, after: 1))
    }
}
