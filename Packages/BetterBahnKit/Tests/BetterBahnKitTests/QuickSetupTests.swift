import Testing
@testable import BetterBahnKit

@Suite struct QuickSetupTests {
    @Test func stepsFollowEachOther() {
        var step: QuickSetupStep? = .ticket
        var visited: [QuickSetupStep] = []
        while let current = step {
            visited.append(current)
            step = current.next
        }
        #expect(visited == QuickSetupStep.allCases)
        #expect(QuickSetupStep.ticket.number == 1)
        #expect(QuickSetupStep.design.number == QuickSetupStep.count)
        #expect(QuickSetupStep.design.next == nil)
    }

    @Test func opensOnlyOnAFreshInstall() {
        #expect(QuickSetup.opensOnLaunch(seen: false, hasUsedApp: false))
        // Seen once, it stays in Settings.
        #expect(!QuickSetup.opensOnLaunch(seen: true, hasUsedApp: false))
        // Updating from a version without it: the app is set up already.
        #expect(!QuickSetup.opensOnLaunch(seen: false, hasUsedApp: true))
        // The debug launch argument: like the first start after installing, every time.
        #expect(QuickSetup.opensOnLaunch(seen: true, hasUsedApp: true, forceFirstStart: true))
    }
}
