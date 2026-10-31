import BetterBahnKit
import OSLog
import SwiftUI
import UIKit

/// The design and accent color picked in Settings › Design (#504). `Color.brand` and the colors derived from it
/// read the accent from here, so every view using them redraws when it changes. Kept per device.
@Observable
final class Theme {
    static let shared = Theme()

    var design: AppDesign {
        didSet { UserDefaults.standard.set(design.rawValue, forKey: "appDesign") }
    }

    var accent: AccentChoice {
        didSet { UserDefaults.standard.set(accent.storageValue, forKey: "accentColor") }
    }

    private static let log = Logger(subsystem: "de.goldkunibert.BetterBahn", category: "theme")

    private init() {
        let defaults = UserDefaults.standard
        design = defaults.string(forKey: "appDesign").flatMap(AppDesign.init) ?? .default
        accent = defaults.string(forKey: "accentColor").flatMap(AccentChoice.init(storageValue:)) ?? .default
    }

    /// Puts the home screen icon of the accent's color in place; iOS confirms the change with an alert of its own,
    /// so this runs when the user is done picking, not on every step of the color picker.
    func applyAppIcon() {
        let name = accent.iconPreset.iconName
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != name else { return }
        Task {
            do {
                try await app.setAlternateIconName(name)
            } catch {
                Self.log.error("App icon not changed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

extension View {
    /// The picked design and accent color for everything below; set once at the app's root.
    func appTheme() -> some View {
        modifier(AppThemeModifier())
    }
}

private struct AppThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.appDesign, Theme.shared.design)
            .tint(Color.brand)
    }
}
