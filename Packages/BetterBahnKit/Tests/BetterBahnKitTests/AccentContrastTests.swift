import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct AccentContrastTests {
    private let lightCard = RGBColor(red: 1, green: 1, blue: 1)
    private let darkCard = RGBColor(red: 0.11, green: 0.11, blue: 0.12)

    @Test func everyPresetIsReadableOnCardsInBothModes() {
        for preset in AccentPreset.allCases {
            #expect(preset.color.readable(on: lightCard).contrastRatio(with: lightCard) >= 3, "\(preset) light")
            #expect(preset.color.readable(on: darkCard).contrastRatio(with: darkCard) >= 3, "\(preset) dark")
        }
    }

    @Test func aReadableColorStaysAsItIs() {
        #expect(AccentPreset.rot.color.readable(on: lightCard) == AccentPreset.rot.color)
    }

    @Test func darkAndLightAccentsMoveAwayFromTheBackground() {
        // Graphit on a dark card gets lighter, a very light color of one's own on a white card darker.
        let graphit = AccentPreset.graphit.color
        #expect(graphit.readable(on: darkCard).relativeLuminance > graphit.relativeLuminance)
        let pale = RGBColor(hex: "#F4F0B0")!
        #expect(pale.readable(on: lightCard).relativeLuminance < pale.relativeLuminance)
        #expect(pale.readable(on: lightCard).contrastRatio(with: lightCard) >= 3)
    }

    @Test func textOnAnAccentFillIsWhiteOnlyWhenItReads() {
        #expect(AccentPreset.rot.color.readableForeground == .white)
        #expect(AccentPreset.graphit.color.readableForeground == .white)
        #expect(RGBColor(hex: "#F4F0B0")!.readableForeground == .black)
        for preset in AccentPreset.allCases {
            #expect(preset.color.contrastRatio(with: preset.color.readableForeground) >= 3, "\(preset)")
        }
    }
}
