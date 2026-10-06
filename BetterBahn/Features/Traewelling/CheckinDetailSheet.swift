import BetterBahnKit
import SwiftUI

/// A leg's Träwelling check-in, opened from "Check-in ansehen" in the leg's "Mehr": shows its text
/// (with the Mastodon instance's emojis) and lets text, visibility and trip type be changed.
struct CheckinDetailSheet: View {
    let leg: Leg
    let statusId: Int

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var status: TraewellingStatus?
    @State private var emojis: [CustomEmoji] = []
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var message = ""
    @State private var visibility: TraewellingVisibility = .publicVisible
    @State private var business: TraewellingBusiness = .privateTrip
    @State private var error: Error?
    @State private var isGone = false

    private var statusURL: URL {
        model.traewelling.config.baseURL.appending(path: "status/\(statusId)")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CheckinTicket(leg: leg)
                    if isLoading {
                        ProgressView().padding()
                    } else if isGone {
                        goneCard
                    } else if isEditing {
                        editCard
                        if let error { ErrorBanner(error: error) }
                        saveButton
                    } else if let status {
                        statusCard(status)
                    } else if let error {
                        ErrorBanner(error: error)
                    }
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button("Abbrechen", systemImage: "xmark", role: .cancel) {
                            withAnimation(.snappy) { isEditing = false; error = nil }
                        }
                    } else {
                        Button("Fertig", systemImage: "checkmark") { dismiss() }
                    }
                }
                if status != nil, !isEditing, !isGone {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Bearbeiten", systemImage: "pencil") { startEditing() }
                    }
                }
            }
            .task { await load() }
        }
    }

    private func statusCard(_ status: TraewellingStatus) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "text.bubble.fill", color: .blue, size: 32)
                    if let body = status.body, !body.isEmpty {
                        EmojiText(text: body, emojis: emojis)
                            .font(.subheadline)
                            .padding(.top, 5)
                            .textSelection(.enabled)
                    } else {
                        Text("Kein Text")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                    }
                }
                HStack(spacing: 8) {
                    if let visibility = status.visibility {
                        InfoChip(text: visibility.label, systemImage: "eye.fill", tint: .purple)
                    }
                    if let business = status.business {
                        InfoChip(text: business.label, systemImage: "briefcase.fill", tint: .orange)
                    }
                }
                Divider()
                Button {
                    openURL(statusURL)
                } label: {
                    Label("Auf Träwelling öffnen", systemImage: "safari")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.brand)
            }
        }
    }

    private var editCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                EmojiMessageField(message: $message, emojis: emojis, placeholder: "Text (optional)")
                Divider()
                menuRow("Sichtbarkeit", icon: "eye.fill", color: .purple, selection: $visibility,
                        options: TraewellingVisibility.allCases) { $0.label }
                Divider()
                menuRow("Reiseart", icon: "briefcase.fill", color: .orange, selection: $business,
                        options: TraewellingBusiness.allCases) { $0.label }
            }
        }
    }

    private var goneCard: some View {
        Card {
            VStack(spacing: 10) {
                IconTile(systemImage: "questionmark.circle.fill", color: .secondary, size: 44)
                Text("Check-in nicht mehr da").font(.headline)
                Text("Träwelling kennt diesen Check-in nicht mehr, vielleicht wurde er gelöscht.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var saveButton: some View {
        Button(action: save) {
            Group {
                if isSaving {
                    ProgressView()
                } else {
                    Label("Speichern", systemImage: "checkmark")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.brand)
        .controlSize(.large)
        .disabled(isSaving || message.count > 280)
    }

    /// Same row as the check-in form's pickers: a `Menu` so long values truncate instead of wrapping.
    private func menuRow<T: Hashable>(_ title: String, icon: String, color: Color,
                                      selection: Binding<T>, options: [T], label: @escaping (T) -> String) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: icon, color: color, size: 32)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        if option == selection.wrappedValue {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                Text(label(selection.wrappedValue))
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 150, alignment: .trailing)
        }
    }

    private func load() async {
        async let emojiList = model.checkinEmojis()
        do {
            status = try await model.traewelling.status(id: statusId)
        } catch TraewellingError.api(let code, _) where code == 404 {
            isGone = true
            model.forgetCheckin(statusId: statusId)
        } catch {
            self.error = error
        }
        emojis = await emojiList
        isLoading = false
    }

    private func startEditing() {
        guard let status else { return }
        message = status.body ?? ""
        visibility = status.visibility ?? model.settings.traewellingVisibility
        business = status.business ?? .privateTrip
        error = nil
        withAnimation(.snappy) { isEditing = true }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let updated = try await model.traewelling.updateStatus(id: statusId, body: message,
                                                                      visibility: visibility, business: business)
                status = updated
                error = nil
                withAnimation(.snappy) { isEditing = false }
            } catch {
                self.error = error
            }
        }
    }
}
