import BetterBahnKit
import SwiftUI

/// A lift out of order (#486), in a transfer row, a leg card or a search result.
struct LiftWarning: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "figure.roll")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.slightDelay)
    }
}

/// The lifts out of order at a station, above its departure board (#486).
struct LiftBanner: View {
    let alerts: [LiftAlert]
    @Environment(\.appDesign) private var design

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                if design == .fahrkarte {
                    // The design's symbols are grey; this one stays a warning.
                    Image(systemName: "figure.roll")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.slightDelay)
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)
                } else {
                    IconTile(systemImage: "figure.roll", color: .slightDelay, size: 34)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(alerts.count == 1 ? "Aufzug defekt" : "\(alerts.count) Aufzüge defekt")
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(design == .fahrkarte ? .rounded : nil)
                    ForEach(alerts) { alert in
                        Text(alert.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
