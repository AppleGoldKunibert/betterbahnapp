import BetterBahnKit
import SwiftUI

// The accent color picked in Settings › Design can be anything from dark graphite to a very light color of
// one's own (#504); these keep text and symbols drawn with it readable in light and dark mode.

extension Color {
    /// The accent for text and symbols on cards and pages: darkened in light mode, lightened in dark mode
    /// just as far as it takes to read well (Kit `RGBColor.readable(on:)`).
    static var brandReadable: Color {
        let accent = Theme.shared.accent.color
        return Color(dynamicUIColor(light: accent.readable(on: .white),
                                    dark: accent.readable(on: RGBColor(red: 0.11, green: 0.11, blue: 0.12))))
    }

    /// Text and symbols on a surface filled with the accent: white, or near-black on a light accent.
    static var brandFillText: Color {
        Theme.shared.accent.color.textColorOnFill.swiftUIColor
    }
}
