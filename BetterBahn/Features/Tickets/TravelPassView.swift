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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pass.name).font(.title2.weight(.bold))
                        if let subtitle = [pass.kindDescription, pass.classDescription].compactMap(\.self).nonEmptyJoined {
                            Text(subtitle).font(.headline).foregroundStyle(.secondary)
                        }
                    }

                    if pass.isExpired() {
                        notice("Abgelaufen. Füg die neue Karte mit einem aktuellen Screenshot hinzu.",
                               systemImage: "exclamationmark.triangle.fill", color: .slightDelay)
                    } else if !pass.isValid(), let from = pass.validFrom {
                        notice("Gilt erst ab \(from.formatted(date: .abbreviated, time: .shortened)).",
                               systemImage: "clock.fill", color: .slightDelay)
                    }

                    // Drawn from the bytes, also for passes saved with the screenshot's cut-out.
                    if let image = DBTicket.Barcode(payload: pass.barcode.payload, image: nil).uiImage {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(20)
                            .frame(maxWidth: .infinity)
                            .background(.white, in: .rect(cornerRadius: 22, style: .continuous))
                            .accessibilityLabel("Ticket-Barcode")
                    }

                    Card { details }

                    AddToWalletButton(payload: WalletPassPayload(pass: pass))

                    Text("Bei der Kontrolle gilt die Karte in der App, in der du sie gekauft hast, z. B. im DB Navigator.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let holder = pass.holder, !holder.name.isEmpty {
                LabeledContent("Inhaber", value: holder.name)
                if let birthDate = holder.birthDateDescription {
                    LabeledContent("Geburtsdatum", value: birthDate)
                }
            }
            if let from = pass.validFrom, let until = pass.validUntil {
                LabeledContent("Gültig") {
                    Text("\(from.formatted(date: .abbreviated, time: .shortened)) –\n\(until.formatted(date: .abbreviated, time: .shortened))")
                        .multilineTextAlignment(.trailing)
                }
            }
            if let issuer = pass.issuer {
                LabeledContent("Ausgestellt von", value: issuer)
            }
        }
        .font(.subheadline)
    }

    private func notice(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

private extension Array where Element == String {
    var nonEmptyJoined: String? { isEmpty ? nil : joined(separator: " · ") }
}
