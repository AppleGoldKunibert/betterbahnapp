import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct AccentContrastTests {
    private let lightPage = RGBColor(red: 0.96, green: 0.955, blue: 0.945)
    private let darkCard = RGBColor(red: 0.12, green: 0.12, blue: 0.13)

    @Test func contrastMatchesWCAG() {
        #expect(abs(RGBColor.white.contrastRatio(to: .black) - 21) < 0.01)
        #expect(abs(RGBColor.white.contrastRatio(to: .white) - 1) < 0.01)
    }

    @Test func readableColorsStayAsTheyAre() {
        let red = AccentPreset.rot.color
        #expect(red.legible(on: lightPage) == red)
        #expect(red.legible(on: darkCard) == red)
    }

    @Test func everyPresetReadsOnLightAndDark() {
        for preset in AccentPreset.allCases {
            #expect(preset.color.legible(on: lightPage).contrastRatio(to: lightPage) >= 3, "\(preset) light")
            #expect(preset.color.legible(on: darkCard).contrastRatio(to: darkCard) >= 3, "\(preset) dark")
        }
    }

    @Test func graphiteIsLightenedOnDark() throws {
        let graphite = AccentPreset.graphit.color
        #expect(graphite.contrastRatio(to: darkCard) < 3)
        let adjusted = graphite.legible(on: darkCard)
        #expect(adjusted.relativeLuminance > graphite.relativeLuminance)
        #expect(adjusted.contrastRatio(to: darkCard) >= 3)
    }

    @Test func paleColorIsDarkenedOnLight() throws {
        let pale = try #require(RGBColor(hex: "#FFF3A0"))
        let adjusted = pale.legible(on: lightPage)
        #expect(adjusted.relativeLuminance < pale.relativeLuminance)
        #expect(adjusted.contrastRatio(to: lightPage) >= 3)
    }

    @Test func whiteTextOnlyOnDarkEnoughFills() throws {
        #expect(AccentPreset.rot.color.legibleForeground == .white)
        #expect(AccentPreset.graphit.color.legibleForeground == .white)
        let pale = try #require(RGBColor(hex: "#FFF3A0"))
        #expect(pale.legibleForeground != .white)
        #expect(pale.legibleForeground.contrastRatio(to: pale) >= 3)
    }

    @Test func storyBackgroundCarriesWhiteText() throws {
        let pale = try #require(RGBColor(hex: "#FFF3A0"))
        #expect(pale.legible(on: .white, minimum: 4.5).contrastRatio(to: .white) >= 4.5)
        #expect(AccentPreset.gold.color.legible(on: .white, minimum: 4.5).contrastRatio(to: .white) >= 4.5)
    }
}
