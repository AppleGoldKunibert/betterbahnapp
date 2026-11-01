import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct AccentContrastTests {
    private let lightCard = RGBColor.white
    private let darkCard = RGBColor(red: 0.11, green: 0.11, blue: 0.12)

    @Test func contrastOfBlackAndWhite() {
        #expect(abs(RGBColor.black.contrastRatio(to: .white) - 21) < 0.01)
        #expect(abs(RGBColor.white.contrastRatio(to: .white) - 1) < 0.01)
    }

    @Test func everyAccentIsReadableAsTextInBothModes() {
        let customs = [RGBColor(hex: "#F4F0C8")!, RGBColor(hex: "#202020")!, RGBColor(hex: "#FFFFFF")!]
        for color in AccentPreset.allCases.map(\.color) + customs {
            #expect(color.readable(on: lightCard).contrastRatio(to: lightCard) >= 4.5, "\(color.hex) light")
            #expect(color.readable(on: darkCard).contrastRatio(to: darkCard) >= 4.5, "\(color.hex) dark")
        }
    }

    @Test func readableAccentStaysWhenItAlreadyIs() {
        let blue = AccentPreset.blau.color
        #expect(blue.readable(on: lightCard) == blue)
    }

    @Test func graphiteGetsLighterInDarkMode() {
        let graphite = AccentPreset.graphit.color
        #expect(graphite.readable(on: darkCard).relativeLuminance > graphite.relativeLuminance)
    }

    @Test func lightFillsGetDarkText() {
        #expect(AccentPreset.rot.color.textColorOnFill == .white)
        #expect(AccentPreset.graphit.color.textColorOnFill == .white)
        #expect(RGBColor(hex: "#F4F0C8")!.textColorOnFill != .white)
        let gold = AccentPreset.gold.color
        #expect(gold.textColorOnFill.contrastRatio(to: gold) >= 3)
    }
}
