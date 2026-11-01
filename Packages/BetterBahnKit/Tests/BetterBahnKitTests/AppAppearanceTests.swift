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

@Suite struct AccentContrastTests {
    private let white = RGBColor(red: 1, green: 1, blue: 1)
    private let darkCard = RGBColor(red: 0.11, green: 0.11, blue: 0.12)

    @Test func contrastRatioMatchesWCAG() {
        #expect(abs(white.contrastRatio(with: RGBColor(red: 0, green: 0, blue: 0)) - 21) < 0.01)
        #expect(abs(white.contrastRatio(with: white) - 1) < 0.0001)
    }

    @Test func everyPresetIsLegibleInBothModes() {
        let light = RGBColor(red: 0.95, green: 0.95, blue: 0.97)
        for preset in AccentPreset.allCases {
            #expect(preset.color.legible(on: light).contrastRatio(with: light) >= 4.5, "\(preset) light")
            #expect(preset.color.legible(on: darkCard).contrastRatio(with: darkCard) >= 4.5, "\(preset) dark")
            #expect(preset.color.legible(on: white, ratio: 3).contrastRatio(with: white) >= 3, "\(preset) fill")
        }
    }

    @Test func graphiteIsLightenedOnDarkAndAVeryLightColorDarkenedOnLight() {
        let graphite = AccentPreset.graphit.color
        #expect(graphite.legible(on: darkCard).relativeLuminance > graphite.relativeLuminance)
        let pale = RGBColor(hex: "#FFF4C0")!
        #expect(pale.legible(on: white).relativeLuminance < pale.relativeLuminance)
    }

    @Test func aLegibleColorStaysAsItIs() {
        let blue = AccentPreset.blau.color
        #expect(blue.legible(on: white) == blue)
    }
}
