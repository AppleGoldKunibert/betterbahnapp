import BetterBahnKit
import SwiftUI

/// "Wagen 2 · Plätze 37, 38" in a train's card, from the journey's ticket.
struct ReservationRow: View {
    let reservation: SeatReservation
    /// bahn.de's request for the train, to tell where the coach stops; nil when there is none yet.
    var request: BahnDeClient.FormationRequest?

    @Environment(AppModel.self) private var model
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "carseat.right.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(reservation.description)
                    .font(.subheadline.weight(.semibold))
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.brand.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sitzplatzreservierung: \([reservation.description, hint].compactMap(\.self).joined(separator: ", "))")
        .task(id: request) {
            hint = nil
            guard let request, !reservation.coach.isEmpty,
                  let sequence = try? await model.coachSequence(for: request), !sequence.coaches.isEmpty else { return }
            hint = switch sequence.position(ofCoach: reservation.coach, train: reservation.trainName) {
            case .sectors(let names, _): "Wagen \(reservation.coach) hält in Abschnitt \(names.joined(separator: "/"))"
            case .noSectors: nil
            case .coachMissing: "Wagen \(reservation.coach) ist in der aktuellen Wagenreihung nicht dabei"
            }
        }
    }
}
