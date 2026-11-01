import Foundation

/// Keeping the accent color readable (#504): any of the presets or a color of one's own, in light and dark mode.
extension RGBColor {
    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    public static let black = RGBColor(red: 0, green: 0, blue: 0)

    /// WCAG relative luminance, 0 (black) … 1 (white).
    public var relativeLuminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio to `other`, 1 … 21.
    public func contrastRatio(to other: RGBColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color, darkened on a light background or lightened on a dark one just as far as it takes to reach
    /// `minimum` contrast to `background`: for accent-colored text and symbols.
    public func readable(on background: RGBColor, minimum: Double = 4.5) -> RGBColor {
        guard contrastRatio(to: background) < minimum else { return self }
        let target: RGBColor = background.relativeLuminance > 0.18 ? .black : .white
        var share = 0.0
        var color = self
        while share < 1, color.contrastRatio(to: background) < minimum {
            share = min(share + 0.05, 1)
            color = mixed(with: target, by: share)
        }
        return color
    }

    /// The text color on a surface filled with this color: white while that stays readable (bold labels need
    /// 3:1), else near-black.
    public var textColorOnFill: RGBColor {
        contrastRatio(to: .white) >= 3 ? .white : RGBColor(red: 0.1, green: 0.1, blue: 0.1)
    }
}
