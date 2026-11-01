import Foundation

// Keeps the freely picked accent color readable (#504): a dark grey on a dark page or a pale yellow on a
// white one is moved just far enough towards black or white, and text on an accent fill turns dark where
// white wouldn't read.
extension RGBColor {
    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    public static let black = RGBColor(red: 0, green: 0, blue: 0)

    /// WCAG relative luminance, 0 (black) … 1 (white).
    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio to `other`, 1 … 21.
    public func contrastRatio(to other: RGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// This color with at least `minimum` contrast on `background`: darkened on a light background,
    /// lightened on a dark one, only as far as needed. Unchanged when it already reads.
    public func legible(on background: RGBColor, minimum: Double = 3) -> RGBColor {
        guard contrastRatio(to: background) < minimum else { return self }
        // Black and white contrast equally with a luminance of about 0.18.
        let target: RGBColor = background.relativeLuminance > 0.18 ? .black : .white
        var share = 0.0
        var color = self
        while share < 1, color.contrastRatio(to: background) < minimum {
            share = min(share + 0.05, 1)
            color = mixed(with: target, by: share)
        }
        return color
    }

    /// Text and symbols on a fill of this color: white where it reads, else a near-black.
    public var legibleForeground: RGBColor {
        contrastRatio(to: .white) >= 3 ? .white : RGBColor(red: 0.1, green: 0.1, blue: 0.1)
    }
}
