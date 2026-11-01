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

    @Test func accentTextIsReadableOnLightAndDarkCards() {
        let light = RGBColor(red: 0.96, green: 0.955, blue: 0.945)
        let dark = RGBColor(red: 0.17, green: 0.17, blue: 0.18)
        let accents = AccentPreset.allCases.map(\.color) + [RGBColor(hex: "#FFF4C2")!, RGBColor(hex: "#101010")!]
        for accent in accents {
            #expect(accent.readable(on: light).contrast(with: light) >= 4.5)
            #expect(accent.readable(on: dark).contrast(with: dark) >= 4.5)
        }
    }

    @Test func readableKeepsColorsThatAlreadyContrast() {
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let red = AccentPreset.rot.color
        #expect(red.readable(on: white) == red)
        // Graphit is lightened on a dark card, Gold darkened on white.
        let graphit = AccentPreset.graphit.color
        #expect(graphit.readable(on: RGBColor(red: 0.11, green: 0.11, blue: 0.12)).relativeLuminance > graphit.relativeLuminance)
        let gold = AccentPreset.gold.color
        #expect(gold.readable(on: white).relativeLuminance < gold.relativeLuminance)
    }

    @Test func lightAccentsGetDarkForeground() {
        #expect(AccentPreset.gold.color.prefersDarkForeground)
        #expect(RGBColor(hex: "#FFF4C2")!.prefersDarkForeground)
        #expect(!AccentPreset.rot.color.prefersDarkForeground)
        #expect(!AccentPreset.graphit.color.prefersDarkForeground)
        #expect(!AccentPreset.blau.color.prefersDarkForeground)
    }
}
