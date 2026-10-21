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

/// "Sitzplatz speichern" next to the Wagenreihung while riding without a reservation (#410), or the seat saved
/// there; a tap picks the coach and seat. The saved coach is highlighted like a reserved one.
struct SaveSeatButton: View {
    let leg: Leg
    /// The coaches with seats, from `CoachSequence.seatCoachNumbers`.
    let coaches: [String]

    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        let saved = model.savedSeat(for: leg)
        let symbol = saved == nil ? "carseat.right" : "carseat.right.fill"
        Button { picking = true } label: {
            // Only the symbol next to a long title.
            ViewThatFits(in: .horizontal) {
                Label(saved?.description ?? "Sitzplatz speichern", systemImage: symbol)
                Image(systemName: symbol)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.brand)
            .lineLimit(1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved.map { "Dein Sitzplatz: \($0.description)" } ?? "Sitzplatz speichern")
        .sheet(isPresented: $picking) {
            SaveSeatSheet(leg: leg, coaches: coaches, saved: saved)
        }
    }
}

/// Picks the coach and, if you like, the seat to save (#410).
private struct SaveSeatSheet: View {
    let leg: Leg
    let coaches: [String]
    let saved: SavedSeat?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var coach: String?
    @State private var seat = ""

    init(leg: Leg, coaches: [String], saved: SavedSeat?) {
        self.leg = leg
        self.coaches = coaches
        self.saved = saved
        _coach = State(initialValue: saved?.coach)
        _seat = State(initialValue: saved?.seat ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(coaches, id: \.self) { number in
                            let selected = coach == number
                            Button { coach = number } label: {
                                Text(number)
                                    .font(.body.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(selected ? Color.brand : Color.secondary.opacity(0.12),
                                                in: .rect(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Wagen \(number)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    TextField("Platz (optional)", text: $seat)
                        .keyboardType(.numberPad)
                        .padding(12)
                        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
                    Text("Dein Wagen wird in der Wagenreihung markiert, so findest du deinen Platz wieder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if saved != nil {
                        Button("Sitzplatz löschen", systemImage: "trash", role: .destructive) {
                            model.saveSeat(nil, for: leg)
                            dismiss()
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .padding()
            }
            .navigationTitle("Wo sitzt du?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern", systemImage: "checkmark") {
                        guard let coach else { return }
                        model.saveSeat(SavedSeat(leg: leg, coach: coach, seat: seat), for: leg)
                        dismiss()
                    }
                    .disabled(coach == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
