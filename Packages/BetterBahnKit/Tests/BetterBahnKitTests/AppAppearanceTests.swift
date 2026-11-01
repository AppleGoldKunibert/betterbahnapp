import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct AppAppearanceTests {
    @Test func hexRoundTrips() throws {
        let color = try #require(RGBColor(hex: "#1F6BD8"))
        #expect(color.hex == "#1F6BD8")
        #expect(RGBColor(hex: "1f6bd8")?.hex == "#1F6BD8")
        #expect(RGBColor(hex: "#12345") == nil)
        #expect(RGBColor(hex: "#GGGGGG") == nil)
    }

    @Test func storageValueRoundTrips() {
        for choice in [AccentChoice.preset(.blau), .preset(.rot), .custom(RGBColor(hex: "#336699")!)] {
            #expect(AccentChoice(storageValue: choice.storageValue) == choice)
        }
        #expect(AccentChoice(storageValue: "unbekannt") == nil)
    }

    @Test func everyPresetIsItsOwnNearest() {
        for preset in AccentPreset.allCases {
            #expect(AccentPreset.nearest(to: preset.color) == preset)
        }
    }

    @Test func customColorsGetTheClosestIcon() {
        #expect(AccentChoice.custom(RGBColor(hex: "#E00000")!).iconPreset == .rot)
        #expect(AccentChoice.custom(RGBColor(hex: "#3080FF")!).iconPreset == .blau)
        #expect(AccentChoice.custom(RGBColor(hex: "#20B060")!).iconPreset == .gruen)
        #expect(AccentChoice.custom(RGBColor(hex: "#555555")!).iconPreset == .graphit)
        #expect(AccentChoice.custom(RGBColor(hex: "#FF8800")!).iconPreset == .orange)
    }

    @Test func onlyRedUsesThePrimaryIcon() {
        #expect(AccentPreset.rot.iconName == nil)
        #expect(AccentPreset.allCases.filter { $0.iconName == nil } == [.rot])
        #expect(Set(AccentPreset.allCases.compactMap(\.iconName)).count == AccentPreset.allCases.count - 1)
    }
}
