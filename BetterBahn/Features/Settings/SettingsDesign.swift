import BetterBahnKit
import SwiftUI

// Building blocks of the forms and lists in Settings, Tickets and Fahrgastrechte, in both designs (#504).

extension View {
    /// A form or list on the design's page: Minimal the grouped background with its faint glow, Fahrkarte the
    /// warm canvas, so the white rows stand out like cards.
    func designedForm() -> some View {
        scrollContentBackground(.hidden)
            .background { AppBackground() }
            // Links, buttons and checkmarks in the accent, kept legible.
            .tint(Color.brandText)
    }
}

extension Color {
    /// Symbol tiles of ordinary settings rows: calm grey, so the accent stays for switches and the few rows that
    /// matter most.
    static let settingsIcon = Color.secondary
}

// The accent where it must stay legible (#504): Graphit is lifted on dark backgrounds, Gold or a very light color
// of one's own is darkened on light ones. Kit `RGBColor.legible(on:ratio:)` does the math.
extension Color {
    /// Light page and card behind the accent in light mode (the grouped background, the darker of the two).
    nonisolated private static let lightSurface = RGBColor(red: 0.95, green: 0.95, blue: 0.97)
    /// Dark card behind the accent in dark mode (the lighter of page and card).
    nonisolated private static let darkSurface = RGBColor(red: 0.11, green: 0.11, blue: 0.12)

    /// The accent as text, links and thin symbols.
    static var brandText: Color { legibleAccent(ratio: 4.5) }

    /// The accent as a switch or other control that must stand out from the page.
    static var brandControl: Color { legibleAccent(ratio: 3) }

    /// The accent as a fill under white text or symbols (the selected coach): darkened until white reads on it.
    static var brandFill: Color {
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let fill = Theme.shared.accent.color.legible(on: white, ratio: 3)
        return Color(dynamicUIColor(light: fill, dark: fill))
    }

    private static func legibleAccent(ratio: Double) -> Color {
        let accent = Theme.shared.accent.color
        return Color(dynamicUIColor(light: accent.legible(on: lightSurface, ratio: ratio),
                                    dark: accent.legible(on: darkSurface, ratio: ratio)))
    }
}

/// A form section's title. Minimal keeps the system's; Fahrkarte sets it bold and rounded like its page titles.
struct FormHeader: View {
    private let title: LocalizedStringKey
    @Environment(\.appDesign) private var design

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        if design == .fahrkarte {
            Text(title)
                .font(.subheadline.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
                .textCase(nil)
        } else {
            Text(title)
        }
    }
}

/// The small capitals above a value on a ticket ("KLASSE", "GÜLTIG"), like the "VON / NACH" of the search.
struct TicketFieldLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
