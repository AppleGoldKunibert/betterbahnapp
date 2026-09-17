import BetterBahnKit
import SwiftUI

struct CheckinSheet: View {
    let leg: Leg

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var visibility: TraewellingVisibility = .publicVisible
    @State private var business: TraewellingBusiness = .privateTrip
    @State private var toot = false
    @State private var isLoggedIn = false
    @State private var isSending = false
    @State private var result: CheckinResult?
    @State private var error: Error?
    @State private var offerManualTrip = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CheckinTicket(leg: leg)

                    if !isLoggedIn {
                        loginCard
                    } else if let result {
                        successCard(result)
                    } else {
                        formCard
                        if let error {
                            ErrorBanner(error: error)
                        }
                        sendButton
                    }
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("Träwelling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: result == nil ? .cancellationAction : .confirmationAction) {
                    if result == nil {
                        Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                    } else {
                        Button("Fertig", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
            .task {
                isLoggedIn = await model.traewelling.isLoggedIn
                visibility = model.settings.traewellingVisibility
            }
            .alert("Zug nicht gefunden", isPresented: $offerManualTrip) {
                Button("Manuell eintragen") { send(allowManualTrip: true) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Träwelling kennt \(leg.line?.name ?? "diesen Zug") nicht. Du kannst ihn manuell eintragen – die Verspätung wird dann automatisch aktualisiert, solange BetterBahn geöffnet ist.")
            }
        }
    }

    private var loginCard: some View {
        Card {
            VStack(spacing: 14) {
                IconTile(systemImage: "person.badge.key.fill", color: .brand, size: 52)
                Text("Bei Träwelling anmelden").font(.headline)
                Text("Zum Einchecken brauchst du ein Träwelling-Konto. Die Anmeldung läuft sicher über traewelling.de.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TraewellingLoginButton { isLoggedIn = true }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func successCard(_ result: CheckinResult) -> some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.punctual.gradient)
                    .symbolEffect(.bounce, value: result.points)
                Text("Eingecheckt").font(.title2.weight(.bold))
                HStack(spacing: 8) {
                    InfoChip(text: "+\(result.points) Punkte", systemImage: "sparkles", tint: .brand)
                    if result.alsoOnThisConnection > 0 {
                        InfoChip(text: "\(result.alsoOnThisConnection) Mitreisende", systemImage: "person.2.fill", tint: .punctual)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var formCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "text.bubble.fill", color: .blue, size: 32)
                    TextField("Was geht ab? (optional)", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(.top, 5)
                }
                if !message.isEmpty {
                    Text("\(message.count)/280")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(message.count > 280 ? Color.heavyDelay : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider()
                pickerRow("Sichtbarkeit", icon: "eye.fill", color: .purple) {
                    Picker("Sichtbarkeit", selection: $visibility) {
                        ForEach(TraewellingVisibility.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Divider()
                pickerRow("Reiseart", icon: "briefcase.fill", color: .orange) {
                    Picker("Reiseart", selection: $business) {
                        ForEach(TraewellingBusiness.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Divider()
                Toggle(isOn: $toot) {
                    HStack(spacing: 12) {
                        IconTile(systemImage: "megaphone.fill", color: .indigo, size: 32)
                        Text("Auf Mastodon teilen").font(.subheadline.weight(.medium))
                    }
                }
                .tint(.brand)
            }
        }
    }

    private func pickerRow<P: View>(_ title: String, icon: String, color: Color, @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: icon, color: color, size: 32)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            picker().labelsHidden().tint(.secondary)
        }
    }

    private var sendButton: some View {
        Button(action: { send() }) {
            Group {
                if isSending {
                    ProgressView()
                } else {
                    Label("Jetzt einchecken", systemImage: "checkmark.seal.fill")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.brand)
        .controlSize(.large)
        .disabled(isSending || message.count > 280)
    }

    private func send(allowManualTrip: Bool = false) {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let checkin = try await attemptCheckin(leg: leg, allowManualTrip: allowManualTrip)
                withAnimation(.bouncy) { result = checkin }
                error = nil
                if checkin.isManualTrip, let statusId = checkin.statusId {
                    model.trackManualCheckin(statusId: statusId, leg: leg)
                }
            } catch OAuthError.notLoggedIn {
                isLoggedIn = false
            } catch TraewellingError.tripNotFound where !allowManualTrip {
                // Some international trains are listed under two names by separate feeds (e.g. an
                // ÖBB "RJ 177" that Deutsche Bahn's own live feed calls "ICE 177") — try the other
                // name Transitous knows about before asking to create a manual entry.
                if let alternate = await model.provider.alternateLineName(for: leg) {
                    var altLeg = leg
                    altLeg.line?.name = alternate
                    if let checkin = try? await attemptCheckin(leg: altLeg, allowManualTrip: false) {
                        withAnimation(.bouncy) { result = checkin }
                        error = nil
                        return
                    }
                }
                offerManualTrip = true
            } catch {
                self.error = error
            }
        }
    }

    private func attemptCheckin(leg: Leg, allowManualTrip: Bool) async throws -> CheckinResult {
        let draft = CheckinDraft(leg: leg, message: message, visibility: visibility, business: business, toot: toot)
        return try await model.traewelling.checkin(draft, allowManualTrip: allowManualTrip)
    }
}

/// Ticket-style summary of the leg.
struct CheckinTicket: View {
    let leg: Leg

    var body: some View {
        let color = leg.line?.product.color ?? .brand
        VStack(spacing: 0) {
            HStack {
                LineBadge(line: leg.line)
                Spacer()
                if let direction = leg.direction {
                    Text("Richtung \(direction)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(14)
            .background(color.gradient)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    TimeStack(time: leg.departure, font: .title2.weight(.bold))
                    Text(leg.origin.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    PlatformBadge(platform: leg.departurePlatform)
                }
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: leg.line?.product.symbolName ?? "tram.fill")
                        .font(.title3)
                        .foregroundStyle(color)
                    Text(leg.arrival.best.timeIntervalSince(leg.departure.best).compactDuration)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    TimeStack(time: leg.arrival, alignment: .trailing, font: .title2.weight(.bold))
                    Text(leg.destination.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    PlatformBadge(platform: leg.arrivalPlatform)
                }
            }
            .padding(16)
        }
        .background(Color.card)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
    }
}

#Preview("Check-in Ticket") {
    VStack {
        CheckinTicket(leg: PreviewData.firstLeg)
    }
    .padding()
    .frame(maxHeight: .infinity)
    .background { AppBackground() }
}
