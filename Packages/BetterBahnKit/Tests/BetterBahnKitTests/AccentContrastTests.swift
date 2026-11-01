import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct AccentContrastTests {
    private let white = RGBColor(red: 1, green: 1, blue: 1)
    /// The card in dark mode (`secondarySystemGroupedBackground`).
    private let darkCard = RGBColor(red: 0.11, green: 0.11, blue: 0.12)
    private let veryLight = RGBColor(hex: "#F4EFD8")!

    @Test func contrastRatioMatchesWCAG() {
        let black = RGBColor(red: 0, green: 0, blue: 0)
        #expect(abs(white.contrastRatio(to: black) - 21) < 0.01)
        #expect(abs(white.contrastRatio(to: white) - 1) < 0.01)
    }

    @Test func everyAccentReadsOnLightAndDarkCards() {
        for color in AccentPreset.allCases.map(\.color) + [veryLight] {
            #expect(color.readable(on: white).contrastRatio(to: white) >= 4.5)
            #expect(color.readable(on: darkCard).contrastRatio(to: darkCard) >= 4.5)
        }
    }

    @Test func readableAccentStaysWhenItReadsAlready() {
        let blue = AccentPreset.blau.color
        #expect(blue.readable(on: white) == blue)
    }

    @Test func graphiteLightensOnDarkAndGoldDarkensOnLight() {
        let graphite = AccentPreset.graphit.color
        #expect(graphite.readable(on: darkCard).relativeLuminance > graphite.relativeLuminance)
        let gold = AccentPreset.gold.color
        #expect(gold.readable(on: white).relativeLuminance < gold.relativeLuminance)
    }

    @Test func foregroundOnAccentIsWhiteOnlyWhereItReads() {
        #expect(AccentPreset.graphit.color.readableForeground == white)
        #expect(AccentPreset.rot.color.readableForeground == white)
        #expect(AccentPreset.gold.color.readableForeground != white)
        #expect(veryLight.readableForeground != white)
        for color in AccentPreset.allCases.map(\.color) + [veryLight] {
            #expect(color.readableForeground.contrastRatio(to: color) >= 3)
        }
    }
}
