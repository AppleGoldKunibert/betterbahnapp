import BetterBahnKit
import SwiftUI

nonisolated private struct BikeModeKey: EnvironmentKey {
    static let defaultValue: BikeOption? = nil
}

extension EnvironmentValues {
    /// The bike (#398) for the journey shown, nil while the search option is off or bikes are hidden in the settings:
    /// its legs say whether it comes along and what it needs, and for a normal bike the Wagenreihung marks the
    /// coaches with bike spaces and where they stop.
    nonisolated var bikeMode: BikeOption? {
        get { self[BikeModeKey.self] }
        set { self[BikeModeKey.self] = newValue }
    }
}

/// Whether `bike` can come along on `leg` and what it needs: the rules right away, then what bahn.de and the train
/// itself say (`AppModel.bikeTransport(for:bike:)`), and where the coaches with bike spaces stop once the
/// Wagenreihung is known.
struct BikeTransportRow: View {
    let leg: Leg
    let bike: BikeOption

    @Environment(AppModel.self) private var model
    @State private var transport: BikeTransport?
    /// "Wagen 1 und 7 · Abschnitt A, E" from the Wagenreihung.
    @State private var coaches: String?

    var body: some View {
        // A ZStack rather than Group: `.task` never fires on a view that is empty.
        ZStack {
            if let transport {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bicycle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color(of: transport))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transport.title)
                            .font(.subheadline.weight(.semibold))
                        ForEach(details(of: transport), id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(color(of: transport).opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
                .transition(.fold)
            }
        }
        .task(id: "\(leg.id)|\(bike.rawValue)") {
            coaches = nil
            transport = BikeTransport.resolved(bahnDe: nil, for: leg, bike: bike)
            let found = await model.bikeTransport(for: leg, bike: bike)
            withAnimation(.snappy) { transport = found }
            guard bike == .bike, found?.kind != .notAllowed, let request = BahnDeClient.formationRequest(for: leg),
                  let sequence = try? await model.coachSequence(for: request) else { return }
            withAnimation(.snappy) { coaches = sequence.bikeCoachSummary.map { String(localized: "Fahrradstellplätze: \($0)") } }
        }
    }

    private func details(of transport: BikeTransport) -> [String] {
        var lines = [transport.section.map { String(localized: "Gilt für \($0)") }, transport.ticket, transport.note]
        if transport.kind != .notAllowed { lines.append(coaches) }
        return lines.compactMap(\.self)
    }

    private func color(of transport: BikeTransport) -> Color {
        switch transport.kind {
        case .allowed, .luggage: transport.ticket == nil ? .punctual : .brand
        case .limited, .reservationRequired: .slightDelay
        case .notAllowed: .heavyDelay
        }
    }
}
