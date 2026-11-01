import Foundation

// Keeps the accent color readable whatever is picked (#504): Graphit on a dark card, Gold or a very light
// color of one's own on a white one.
public extension RGBColor {
    /// WCAG relative luminance, 0 (black) … 1 (white).
    var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio to `other`, 1 … 21.
    func contrastRatio(to other: RGBColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color as text or a thin mark on `background`: unchanged when it reads already, else moved towards
    /// black (on a light background) or white (on a dark one) just far enough to reach `minimumContrast`.
    func readable(on background: RGBColor, minimumContrast: Double = 4.5) -> RGBColor {
        let target = background.relativeLuminance > 0.18 ? RGBColor(red: 0, green: 0, blue: 0)
                                                          : RGBColor(red: 1, green: 1, blue: 1)
        for step in 0...20 {
            let candidate = mixed(with: target, by: Double(step) / 20)
            if candidate.contrastRatio(to: background) >= minimumContrast { return candidate }
        }
        return target
    }

    /// White, or black where white would be hard to read: for text and symbols on a surface of this color.
    /// Bold labels on a filled surface need less contrast than body text, so white wins down to 3:1.
    var readableForeground: RGBColor {
        let white = RGBColor(red: 1, green: 1, blue: 1)
        return contrastRatio(to: white) >= 3 ? white : RGBColor(red: 0, green: 0, blue: 0)
    }
}
