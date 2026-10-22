import Testing
@testable import BetterBahnKit

/// The iPad's and the Mac's two columns (#425).
@Suite struct SplitLayoutTests {
    @Test func sidebarStaysBetweenItsLimits() {
        // iPad mini in portrait, a narrow Split View window and a 13-inch iPad in landscape.
        #expect(SplitLayout.sidebarWidth(for: 744) == 320)
        #expect(SplitLayout.sidebarWidth(for: 900) == 360)
        #expect(SplitLayout.sidebarWidth(for: 1366) == 420)
    }

    @Test func detailsKeepMostOfTheWindow() {
        for width in stride(from: 700.0, through: 2000, by: 50) {
            #expect(width - SplitLayout.sidebarWidth(for: width) >= width * 0.5)
        }
    }
}
