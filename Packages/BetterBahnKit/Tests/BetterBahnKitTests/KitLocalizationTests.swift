import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct KitLocalizationTests {
    @Test func testsGetGerman() {
        #expect(KitLocalization.isGerman)
        #expect(String(kit: "Gleis %@ statt %@", "4", "2") == "Gleis 4 statt 2")
    }

    @Test func fillsPlaceholdersInOrderAndByPosition() {
        #expect(KitLocalization.format("%lld Min. bis %@", [5, "Köln Hbf"]) == "5 Min. bis Köln Hbf")
        #expect(KitLocalization.format("%2$@ in %1$lld min", [5, "Köln Hbf"]) == "Köln Hbf in 5 min")
        #expect(KitLocalization.format("%lld %% belegt", [80]) == "80 % belegt")
        #expect(KitLocalization.format("100 %", []) == "100 %")
    }

    @Test func liveActivityWarningsFromTheServer() {
        // The server writes these in German; in German they stay as they are.
        #expect(TripActivityAttributes.ContentState.localizedWarning("RE 3 fällt aus") == "RE 3 fällt aus")
        #expect(TripActivityAttributes.ContentState.localizedWarning("Umstieg in Köln Hbf klappt nicht mehr")
            == "Umstieg in Köln Hbf klappt nicht mehr")
        #expect(TripActivityAttributes.ContentState.localizedWarning("Anything else") == "Anything else")
    }
}
