import BetterBahnKit
import SwiftUI

/// A leg's Träwelling check-in, opened from "Check-in ansehen" in the leg's "Mehr": shows its text
/// (with the Mastodon instance's emojis) and tags, lets text, visibility, trip type and tags be changed
/// and the check-in be deleted. Below it, the others checked in to the same train ("Mitreisende").
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
    @State private var tags: [StatusTag] = []
    @State private var editedTags: [StatusTag] = []
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var fellowTravellers: [TraewellingStatus] = []

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
                        if !fellowTravellers.isEmpty { fellowTravellersSection }
                        if let error { ErrorBanner(error: error) }
                        deleteButton
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let visibility = status.visibility {
                            InfoChip(text: visibility.label, systemImage: "eye.fill", tint: .purple)
                        }
                        if let business = status.business {
                            InfoChip(text: business.label, systemImage: "briefcase.fill", tint: .orange)
                        }
                        ForEach(tags, id: \.key) { tag in
                            InfoChip(text: "\(tagLabel(tag.key)): \(tag.value)", systemImage: tagIcon(tag.key), tint: .brand)
                        }
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

    private var fellowTravellersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Mitreisende", systemImage: "person.2.fill", trailing: "\(fellowTravellers.count)")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(fellowTravellers.enumerated()), id: \.element.id) { index, fellow in
                        if index > 0 { Divider() }
                        fellowTravellerRow(fellow)
                    }
                }
            }
        }
    }

    /// Someone else on this train: who, and from where to where; opens their profile on Träwelling.
    private func fellowTravellerRow(_ fellow: TraewellingStatus) -> some View {
        let baseURL = model.traewelling.config.baseURL
        let url = fellow.user.map { baseURL.appending(path: "@\($0.username)") } ?? baseURL.appending(path: "status/\(fellow.id)")
        let origin = fellow.checkin.origin.station?.name ?? fellow.checkin.origin.name ?? "?"
        let destination = fellow.checkin.destination.station?.name ?? fellow.checkin.destination.name ?? "?"
        return Button {
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: fellow.user?.profilePicture) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 36, height: 36)
                .clipShape(.circle)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(fellow.user?.displayName ?? "Träwelling-Nutzer")
                            .font(.subheadline.weight(.semibold))
                        if let username = fellow.user?.username {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    Text("\(origin) → \(destination)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
                Divider()
                tagsEditor
            }
        }
    }

    /// The check-in's tags with their values, plus the quick tags from the settings to add.
    private var tagsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(systemImage: "tag.fill", color: .brand, size: 32)
                Text("Tags").font(.subheadline.weight(.medium))
                Spacer()
            }
            ForEach($editedTags, id: \.key) { $tag in
                HStack(spacing: 8) {
                    Label(tagLabel(tag.key), systemImage: tagIcon(tag.key))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.brand)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                    TextField(tagLabel(tag.key), text: $tag.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                    Button("Tag entfernen", systemImage: "minus.circle.fill") {
                        let key = tag.key
                        withAnimation(.snappy) { editedTags.removeAll { $0.key == key } }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.heavyDelay)
                    .buttonStyle(.plain)
                }
            }
            let addable = model.settings.quickTags.filter { quick in !editedTags.contains { $0.key == quick.key } }
            if !addable.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(addable) { quick in
                            Button {
                                withAnimation(.snappy) {
                                    editedTags.append(StatusTag(key: quick.key, value: quick.value ?? "", visibility: visibility))
                                }
                            } label: {
                                Label(quick.label, systemImage: "plus")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(Color.brand)
                                    .background(Color.brand.opacity(0.12), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Group {
                if isDeleting {
                    ProgressView()
                } else {
                    Label("Check-in löschen", systemImage: "trash")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(.red)
        .controlSize(.large)
        .disabled(isDeleting)
        .confirmationDialog("Check-in löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive, action: delete)
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Check-in wird bei Träwelling gelöscht, mit seinen Punkten.")
        }
    }

    /// A tag's name: the quick tag's label for its key, else the key without Träwelling's prefix.
    private func tagLabel(_ key: String) -> String { model.statusTagLabel(key) }

    private func tagIcon(_ key: String) -> String { model.statusTagIcon(key) }

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
        async let tagList = loadTags()
        do {
            status = try await model.traewelling.status(id: statusId)
        } catch TraewellingError.api(let code, _) where code == 404 {
            isGone = true
            model.forgetCheckin(statusId: statusId)
        } catch {
            self.error = error
        }
        emojis = await emojiList
        tags = await tagList
        isLoading = false
        // Extra too: the section only shows once someone else is on the train.
        if let status { fellowTravellers = (try? await model.traewelling.fellowTravellers(of: status)) ?? [] }
    }

    /// Tags are extra: the check-in still shows when they can't be loaded.
    private func loadTags() async -> [StatusTag] {
        (try? await model.traewelling.tags(statusId: statusId)) ?? []
    }

    private func startEditing() {
        guard let status else { return }
        message = status.body ?? ""
        visibility = status.visibility ?? model.settings.traewellingVisibility
        business = status.business ?? .privateTrip
        editedTags = tags
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
                tags = try await model.traewelling.applyTagChanges(statusId: statusId, from: tags, to: editedTags)
                error = nil
                withAnimation(.snappy) { isEditing = false }
            } catch {
                self.error = error
                // Some tag changes may have gone through; the next try starts from what Träwelling has.
                if let current = try? await model.traewelling.tags(statusId: statusId) { tags = current }
            }
        }
    }

    private func delete() {
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await model.deleteCheckin(statusId: statusId)
                dismiss()
            } catch {
                self.error = error
            }
        }
    }
}
