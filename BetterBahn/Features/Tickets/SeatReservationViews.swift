import BetterBahnKit
import SwiftUI

/// "Wagen 2 · Plätze 37, 38" in a train's card, from the journey's ticket.
struct ReservationRow: View {
    let reservation: SeatReservation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "carseat.right.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 22)
            Text(reservation.description)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.brand.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sitzplatzreservierung: \(reservation.description)")
    }
}
