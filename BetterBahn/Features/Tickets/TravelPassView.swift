import BetterBahnKit
import SwiftUI

/// A pass such as the Deutschland-Ticket, ready for a ticket check: barcode as large as possible
/// with the screen at full brightness.
struct TravelPassView: View {
    let pass: TravelPass
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TicketFace(title: pass.name, subtitle: pass.classDescription, details: details) {
                        if pass.isExpired() {
                            TicketNote(text: String(localized: "Abgelaufen. Füg die neue Karte mit einem aktuellen Screenshot hinzu."),
                                       systemImage: "exclamationmark.triangle.fill", color: .slightDelay, emphasized: true)
                        } else if !pass.isValid(), let from = pass.validFrom {
                            TicketNote(text: String(localized: "Gilt erst ab \(from.formatted(date: .abbreviated, time: .shortened))."),
                                       systemImage: "clock.fill", color: .slightDelay, emphasized: true)
                        }
                    } code: {
                        // Drawn from the bytes, also for passes saved with the screenshot's cut-out.
                        if let image = DBTicket.Barcode(payload: pass.barcode.payload, image: nil).uiImage {
                            TicketBarcode(image: image)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        AddToWalletButton(payload: WalletPassPayload(pass: pass))

                        Text("Bei der Kontrolle gilt die Karte in der App, in der du sie gekauft hast, z. B. im DB Navigator.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("Zeitkarte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .fullBrightness()
    }

    private var details: [TicketDetail] {
        var details: [TicketDetail] = []
        if let holder = pass.holder, !holder.name.isEmpty {
            details.append(TicketDetail(label: String(localized: "Inhaber"), value: holder.name))
            if let birthDate = holder.birthDateDescription {
                details.append(TicketDetail(label: String(localized: "Geburtsdatum"), value: birthDate))
            }
        }
        if let from = pass.validFrom, let until = pass.validUntil {
            details.append(TicketDetail(label: String(localized: "Gültig"),
                                        value: String(localized: "\(from.formatted(date: .abbreviated, time: .shortened)) –\n\(until.formatted(date: .abbreviated, time: .shortened))")))
        }
        if let issuer = pass.issuer {
            details.append(TicketDetail(label: String(localized: "Ausgestellt von"), value: issuer))
        }
        return details
    }
}
