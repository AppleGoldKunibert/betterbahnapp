import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct LiveDataCacheTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func keepsWhatWasSeenUntilItIsTooOld() {
        var cache = LiveDataCache<String>()
        #expect(cache.value(for: "ice940", now: now) == nil)
        cache.store("live", for: "ice940", now: now)
        #expect(cache.value(for: "ice940", now: now.addingTimeInterval(3600)) == "live")
        #expect(cache.value(for: "ice940", now: now.addingTimeInterval(LiveDataCache<String>.maxAge)) == nil)
    }

    @Test func keepsOnlyTheNewestEntries() {
        var cache = LiveDataCache<Int>()
        let limit = LiveDataCache<Int>.limit
        for index in 0...limit {
            cache.store(index, for: "trip\(index)", now: now.addingTimeInterval(Double(index)))
        }
        let later = now.addingTimeInterval(Double(limit))
        #expect(cache.value(for: "trip0", now: later) == nil)
        #expect(cache.value(for: "trip1", now: later) == 1)
        #expect(cache.value(for: "trip\(limit)", now: later) == limit)
    }

    /// Kept on disk by the app, so it has to survive a round trip through JSON.
    @Test func survivesARestart() throws {
        var cache = LiveDataCache<String>()
        cache.store("live", for: "ice940")
        let decoded = try JSONDecoder().decode(LiveDataCache<String>.self, from: JSONEncoder().encode(cache))
        #expect(decoded.value(for: "ice940") == "live")
    }
}
