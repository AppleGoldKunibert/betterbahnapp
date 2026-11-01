import Foundation

// Keeps the accent color legible whatever the user picks (#504): Graphit on dark backgrounds, Gold or a very
// light color of one's own on light ones.

extension RGBColor {
    /// WCAG relative luminance, 0 (black) … 1 (white).
    public var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 … 21.
    public func contrastRatio(with other: RGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// This color, moved towards black on a light background or towards white on a dark one just far enough
    /// to reach `ratio` against `background` (4.5 for text, 3 for symbols, controls and bold large text).
    /// Unchanged when it already does.
    public func legible(on background: RGBColor, ratio: Double = 4.5) -> RGBColor {
        guard contrastRatio(with: background) < ratio else { return self }
        let lightBackground = background.contrastRatio(with: RGBColor(red: 0, green: 0, blue: 0))
            >= background.contrastRatio(with: RGBColor(red: 1, green: 1, blue: 1))
        let target = lightBackground ? RGBColor(red: 0, green: 0, blue: 0) : RGBColor(red: 1, green: 1, blue: 1)
        for step in 1...40 {
            let candidate = mixed(with: target, by: Double(step) / 40)
            if candidate.contrastRatio(with: background) >= ratio { return candidate }
        }
        return target
    }
}
