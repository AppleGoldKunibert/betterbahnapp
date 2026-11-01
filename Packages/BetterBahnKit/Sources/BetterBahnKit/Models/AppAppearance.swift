import Foundation

/// The look of the app, chosen in Settings › Design (#504).
public enum AppDesign: String, Codable, CaseIterable, Sendable {
    /// The familiar cards and glow, kept quiet: options folded away, flat buttons.
    case minimal
    /// The search as a ticket: flat cards, rounded type, a warm page.
    case fahrkarte

    public static let `default` = AppDesign.minimal
}

/// An sRGB color, components 0…1.
public struct RGBColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// "#RRGGBB" or "RRGGBB"; nil for anything else.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// "#RRGGBB", upper case.
    public var hex: String {
        func byte(_ component: Double) -> Int { Int((component * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// This color moved `share` (0…1) of the way towards `other`.
    public func mixed(with other: RGBColor, by share: Double) -> RGBColor {
        RGBColor(red: red + (other.red - red) * share, green: green + (other.green - green) * share,
                 blue: blue + (other.blue - blue) * share)
    }

    /// Hue (0…1), saturation and brightness.
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(red, green, blue), minValue = min(red, green, blue), delta = maxValue - minValue
        guard delta > 0 else { return (0, 0, maxValue) }
        var hue: Double
        if maxValue == red {
            hue = (green - blue) / delta
        } else if maxValue == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maxValue, maxValue)
    }

    /// How different two colors look: hue counts most for colorful ones, brightness and saturation for greys.
    func distance(to other: RGBColor) -> Double {
        let a = hsb, b = other.hsb
        var hueGap = abs(a.hue - b.hue)
        hueGap = min(hueGap, 1 - hueGap) * 2
        // Hue means little for washed-out colors.
        let colorfulness = min(a.saturation, b.saturation)
        return hueGap * colorfulness * 3 + abs(a.saturation - b.saturation) + abs(a.brightness - b.brightness)
    }
}

/// Contrast, so the accent color stays readable whatever the user picks (#504): Graphit on a dark card, Gold or a
/// very light color of one's own on white.
extension RGBColor {
    /// WCAG relative luminance, 0 (black) … 1 (white).
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio with `other`, 1 … 21.
    public func contrast(with other: RGBColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color, darkened on a light `background` or lightened on a dark one just enough for text in it to
    /// reach `minimumContrast` (4.5: normal text); unchanged when it already does.
    public func readable(on background: RGBColor, minimumContrast: Double = 4.5) -> RGBColor {
        let target = background.relativeLuminance > 0.18 ? RGBColor(red: 0, green: 0, blue: 0)
                                                         : RGBColor(red: 1, green: 1, blue: 1)
        var color = self
        var share = 0.0
        while color.contrast(with: background) < minimumContrast, share < 1 {
            share = min(share + 0.04, 1)
            color = mixed(with: target, by: share)
        }
        return color
    }

    /// Text and symbols on a surface filled with this color should be dark: white would not stand out enough
    /// (contrast below 3, the minimum for bold or large text).
    public var prefersDarkForeground: Bool {
        contrast(with: RGBColor(red: 1, green: 1, blue: 1)) < 3
    }
}

/// The ten accent colors on offer, each with an app icon of its own.
public enum AccentPreset: String, Codable, CaseIterable, Sendable {
    case rot, orange, gold, gruen, tuerkis, blau, indigo, lila, pink, graphit

    public var color: RGBColor {
        switch self {
        case .rot: RGBColor(red: 0.86, green: 0.09, blue: 0.19)
        case .orange: RGBColor(hex: "#E8650F")!
        case .gold: RGBColor(hex: "#C98F06")!
        case .gruen: RGBColor(hex: "#1E9A55")!
        case .tuerkis: RGBColor(hex: "#0B93A1")!
        case .blau: RGBColor(hex: "#1F6BD8")!
        case .indigo: RGBColor(hex: "#4A45CF")!
        case .lila: RGBColor(hex: "#8A3CCF")!
        case .pink: RGBColor(hex: "#D92D78")!
        case .graphit: RGBColor(hex: "#3D434B")!
        }
    }

    /// The alternate app icon's name in the asset catalog; nil for red, the primary icon.
    public var iconName: String? {
        switch self {
        case .rot: nil
        case .orange: "AppIcon-Orange"
        case .gold: "AppIcon-Gold"
        case .gruen: "AppIcon-Gruen"
        case .tuerkis: "AppIcon-Tuerkis"
        case .blau: "AppIcon-Blau"
        case .indigo: "AppIcon-Indigo"
        case .lila: "AppIcon-Lila"
        case .pink: "AppIcon-Pink"
        case .graphit: "AppIcon-Graphit"
        }
    }

    /// The preset that looks most like `color`.
    public static func nearest(to color: RGBColor) -> AccentPreset {
        allCases.min { $0.color.distance(to: color) < $1.color.distance(to: color) } ?? .rot
    }
}

/// The accent color the user picked: one of the presets or any color of their own.
public enum AccentChoice: Hashable, Sendable {
    case preset(AccentPreset)
    case custom(RGBColor)

    public static let `default` = AccentChoice.preset(.rot)

    public var color: RGBColor {
        switch self {
        case .preset(let preset): preset.color
        case .custom(let color): color
        }
    }

    /// The preset whose app icon fits: the preset itself, or the closest one to a color of the user's own.
    public var iconPreset: AccentPreset {
        switch self {
        case .preset(let preset): preset
        case .custom(let color): AccentPreset.nearest(to: color)
        }
    }

    /// As stored in the settings: a preset's name or "#RRGGBB".
    public var storageValue: String {
        switch self {
        case .preset(let preset): preset.rawValue
        case .custom(let color): color.hex
        }
    }

    public init?(storageValue: String) {
        if let preset = AccentPreset(rawValue: storageValue) {
            self = .preset(preset)
        } else if let color = RGBColor(hex: storageValue) {
            self = .custom(color)
        } else {
            return nil
        }
    }
}
