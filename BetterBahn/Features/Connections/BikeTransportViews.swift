import BetterBahnKit
import SwiftUI

nonisolated private struct BikeModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// "Mit Fahrrad" (#398) for the journey shown: its legs say whether a bike can come along, and the
    /// Wagenreihung marks the coaches with bike spaces and where they stop.
    nonisolated var bikeMode: Bool {
        get { self[BikeModeKey.self] }
        set { self[BikeModeKey.self] = newValue }
    }
}

/// In bike mode, whether a bike can come along on `leg`: the rule of thumb right away, then what bahn.de says
/// (`AppModel.bikeTransport(for:)`), and where the coaches with bike spaces stop once the Wagenreihung is known.
struct BikeTransportRow: View {
    let leg: Leg

    @Environment(AppModel.self) private var model
    @State private var transport: BikeTransport?
    /// "Wagen 1 und 7 · Abschnitt A, E" from the Wagenreihung.
    @State private var coaches: String?

    var body: some View {
        // A ZStack rather than Group: `.task` never fires on a view that is empty.
        ZStack {
            if let transport {
                HStack(spacing: 10) {
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
        .task(id: leg.id) {
            transport = BikeTransport.resolved(bahnDe: nil, for: leg)
            let found = await model.bikeTransport(for: leg)
            withAnimation(.snappy) { transport = found }
            guard found?.kind != .notAllowed, let request = BahnDeClient.formationRequest(for: leg),
                  let sequence = try? await model.coachSequence(for: request) else { return }
            withAnimation(.snappy) { coaches = sequence.bikeCoachSummary.map { "Fahrradstellplätze: \($0)" } }
        }
    }

    private func details(of transport: BikeTransport) -> [String] {
        [transport.section.map { "Gilt für \($0)" }, transport.kind == .notAllowed ? nil : coaches].compactMap(\.self)
    }

    private func color(of transport: BikeTransport) -> Color {
        switch transport.kind {
        case .allowed: .punctual
        case .limited, .reservationRequired: .slightDelay
        case .notAllowed: .heavyDelay
        }
    }
}
