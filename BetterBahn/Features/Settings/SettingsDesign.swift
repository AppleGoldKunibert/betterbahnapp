import SwiftUI

// Building blocks of the forms and lists in Settings, Tickets and Fahrgastrechte, in both designs (#504).

extension View {
    /// A form or list on the design's page: Minimal the grouped background with its faint glow, Fahrkarte the
    /// warm canvas, so the white rows stand out like cards.
    func designedForm() -> some View {
        scrollContentBackground(.hidden)
            .background { AppBackground() }
    }
}

extension Color {
    /// Symbol tiles of ordinary settings rows: calm grey, so the accent stays for switches and the few rows that
    /// matter most.
    static let settingsIcon = Color.secondary
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
