import Foundation

// Keeps the picked accent color (#504) readable: as text or a symbol on a card, and under text on an accent fill.

extension RGBColor {
    static let black = RGBColor(red: 0, green: 0, blue: 0)
    static let white = RGBColor(red: 1, green: 1, blue: 1)

    /// WCAG relative luminance, 0 (black) … 1 (white).
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio with `other`, 1 … 21.
    public func contrastRatio(with other: RGBColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color as text or a symbol on `background`: unchanged when it contrasts enough, else darkened (on a
    /// light background) or lightened (on a dark one) just far enough to reach `minimum`.
    public func readable(on background: RGBColor, minimum: Double = 3) -> RGBColor {
        guard contrastRatio(with: background) < minimum else { return self }
        let target = background.contrastRatio(with: .black) >= background.contrastRatio(with: .white) ? RGBColor.black : .white
        for step in 1...20 {
            let candidate = mixed(with: target, by: Double(step) / 20)
            if candidate.contrastRatio(with: background) >= minimum { return candidate }
        }
        return target
    }

    /// The text color on a fill of this color: white while it reads well (contrast of at least 3, enough for
    /// bold button labels), else black.
    public var readableForeground: RGBColor {
        contrastRatio(with: .white) >= 3 ? .white : .black
    }
}
