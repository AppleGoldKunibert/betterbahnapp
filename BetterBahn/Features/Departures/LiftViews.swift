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

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemImage: "figure.roll", color: .slightDelay, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(alerts.count == 1 ? "Aufzug defekt" : "\(alerts.count) Aufzüge defekt")
                        .font(.subheadline.weight(.semibold))
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
