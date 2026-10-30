import Testing
@testable import BetterBahnKit

/// Which phone screens turn the app sideways (#487).
@Suite struct ScreenRotationTests {
    @Test func phonesStayUpright() {
        #expect(!ScreenRotation.turnsFreely(width: 1206, height: 2622)) // iPhone 17 Pro
        #expect(!ScreenRotation.turnsFreely(width: 1320, height: 2868)) // iPhone 17 Pro Max
        #expect(!ScreenRotation.turnsFreely(width: 750, height: 1334)) // 16:9 iPhone SE
    }

    @Test func duoScreensTurnFreely() {
        #expect(ScreenRotation.turnsFreely(width: 1398, height: 2034)) // folded
        #expect(ScreenRotation.turnsFreely(width: 2853, height: 2007)) // unfolded, sideways
        #expect(ScreenRotation.turnsFreely(width: 2007, height: 2853)) // unfolded, upright
    }

    @Test func noScreenStaysUpright() {
        #expect(!ScreenRotation.turnsFreely(width: 0, height: 0))
    }
}
