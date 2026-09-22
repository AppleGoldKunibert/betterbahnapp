import BetterBahnKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var user: TraewellingUser?
    @State private var isLoggedIn = false
    @State private var showClearHistoryConfirmation = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        IconTile(systemImage: "tram.fill", color: .brand, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BetterBahn").font(.title3.weight(.bold))
                            Text("Bahnfahren, aber besser.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if settings.traewellingEnabled {
                    traewellingSection
                }

                Section {
                    Picker(selection: $settings.ticketType) {
                        ForEach(TicketType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    } label: {
                        IconLabel(title: "Mein Ticket", systemImage: settings.ticketType.symbolName, color: .brand)
                    }
                    Toggle(isOn: $settings.ticketFilterByDefault) {
                        IconLabel(title: "Nur passende Züge zeigen",
                                  systemImage: "line.3.horizontal.decrease.circle.fill", color: .brand)
                    }
                    .tint(.brand)
                    if settings.ticketType == .bahnCard100 {
                        NavigationLink {
                            BC100RulesView()
                        } label: {
                            IconLabel(title: "Ausgeschlossene Anbieter", systemImage: "nosign", color: .orange)
                        }
                    }
                } header: {
                    Text("Ticket")
                } footer: {
                    Text(settings.ticketType == .deutschlandticket
                         ? "Blendet Fernzüge wie ICE und IC aus, in denen das Deutschlandticket nicht gilt."
                         : "Blendet Züge aus, in denen die BahnCard 100 nicht gilt, z. B. FlixTrain.")
                }

                Section {
                    Toggle(isOn: $settings.connectionWarnings) {
                        IconLabel(title: "Bei Problemen benachrichtigen", systemImage: "exclamationmark.triangle.fill", color: .orange)
                    }
                    .tint(.brand)
                    .onChange(of: settings.connectionWarnings) { _, enabled in
                        if enabled { Task { await ConnectionNotifier.requestAuthorization() } }
                    }
                    Button {
                        Task { await model.liveActivities.endAll() }
                    } label: {
                        IconLabel(title: "Live-Aktivitäten beenden", systemImage: "stop.circle.fill", color: .indigo)
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Meine Reisen")
                } footer: {
                    Text("Wir sagen dir Bescheid, wenn ein Zug ausfällt oder du deinen Anschluss verpasst.")
                }

                Section {
                    Button(role: .destructive) {
                        showClearHistoryConfirmation = true
                    } label: {
                        IconLabel(title: "Suchverlauf löschen", systemImage: "clock.arrow.circlepath", color: .heavyDelay)
                    }
                } footer: {
                    Text("Favoriten und gespeicherte Reisen bleiben erhalten.")
                }

                Section {
                    Toggle(isOn: $settings.expertMode.animation()) {
                        IconLabel(title: "Expertenmodus", systemImage: "wand.and.stars", color: .indigo)
                    }
                    .tint(.brand)
                    if settings.expertMode {
                        Toggle(isOn: $settings.expertTraewelling) {
                            IconLabel(title: "Träwelling", systemImage: "checkmark.seal.fill", color: .brand)
                        }
                        .tint(.brand)
                        Toggle(isOn: $settings.expertEditJourney) {
                            IconLabel(title: "Reise bearbeiten", systemImage: "pencil", color: .orange)
                        }
                        .tint(.brand)
                        Toggle(isOn: $settings.expertTrainChoice) {
                            IconLabel(title: "Bestimmten Zug wählen", systemImage: "number", color: .purple)
                        }
                        .tint(.brand)
                    }
                } header: {
                    Text("Für Profis")
                } footer: {
                    Text("Zusätzliche Funktionen für Vielfahrer. Schalte nur ein, was du brauchst.")
                }

                Section {
                    LabeledContent("Fahrplandaten", value: "Transitous")
                } footer: {
                    Text("[Quellen](https://transitous.org/sources/) · [© OpenStreetMap](https://www.openstreetmap.org/copyright)")
                }
            }
            .navigationTitle("Einstellungen")
            .task { await refreshLogin() }
            .confirmationDialog(
                "Suchverlauf löschen?",
                isPresented: $showClearHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button("Suchverlauf löschen", role: .destructive) {
                    model.clearSearchHistory()
                }
            } message: {
                Text("Favoriten, gespeicherte Reisen und deine Anmeldung bleiben erhalten.")
            }
        }
    }

    private var traewellingSection: some View {
        @Bindable var settings = model.settings
        return Section {
            if isLoggedIn {
                HStack(spacing: 12) {
                    IconTile(systemImage: "person.crop.circle.badge.checkmark", color: .punctual)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user?.displayName ?? "Angemeldet").font(.body.weight(.semibold))
                        if let user {
                            Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let points = user?.points {
                        InfoChip(text: "\(points)", systemImage: "sparkles", tint: .brand)
                    }
                }
                Button(role: .destructive) {
                    Task {
                        await model.traewelling.logout()
                        await refreshLogin()
                    }
                } label: {
                    IconLabel(title: "Abmelden", systemImage: "rectangle.portrait.and.arrow.right", color: .heavyDelay)
                }
            } else {
                TraewellingLoginButton { Task { await refreshLogin() } }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Toggle(isOn: $settings.syncTraewellingToMap) {
                IconLabel(title: "Fahrten auf der Karte zeigen", systemImage: "map.fill", color: .teal)
            }
            .tint(.brand)
            if isLoggedIn, settings.syncTraewellingToMap {
                Button {
                    Task { await model.syncTraewelling(force: true) }
                } label: {
                    HStack {
                        IconLabel(title: "Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath", color: .blue)
                        Spacer()
                        if model.isSyncingTraewelling {
                            ProgressView()
                        } else {
                            Text("\(model.traewellingTrips.count) Fahrten")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .disabled(model.isSyncingTraewelling)
            }
            Picker(selection: $settings.traewellingVisibility) {
                ForEach(TraewellingVisibility.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                IconLabel(title: "Sichtbarkeit", systemImage: "eye.fill", color: .purple)
            }
            NavigationLink {
                QuickTagsView()
            } label: {
                IconLabel(title: "Tags", systemImage: "tag.fill", color: .brand)
            }
        } header: {
            Text("Träwelling")
        }
    }

    private func refreshLogin() async {
        isLoggedIn = await model.traewelling.isLoggedIn
        user = isLoggedIn ? try? await model.traewelling.currentUser() : nil
    }
}

struct BC100RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var operators = ""
    @State private var prefixes = ""

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "info.circle.fill", color: .blue)
                    Text("Die BahnCard 100 gilt nicht bei allen Anbietern. Hier kannst du die Liste anpassen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Anbieter", text: $operators, axis: .vertical)
            } header: {
                Label("Anbieter (mit Komma trennen)", systemImage: "building.2.fill")
            } footer: {
                Text("Züge dieser Anbieter werden ausgeblendet.")
            }
            Section {
                TextField("Präfixe", text: $prefixes, axis: .vertical)
            } header: {
                Label("Zugnamen, die beginnen mit (mit Komma trennen)", systemImage: "textformat.abc")
            }
            Section {
                Button {
                    load(.default)
                    save()
                } label: {
                    IconLabel(title: "Standard wiederherstellen", systemImage: "arrow.counterclockwise", color: .gray)
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("BahnCard 100")
        .onAppear { load(model.settings.bc100Rules) }
        .onDisappear(perform: save)
    }

    private func load(_ rules: BC100Rules) {
        operators = rules.excludedOperators.joined(separator: ", ")
        prefixes = rules.excludedLinePrefixes.joined(separator: ", ")
    }

    private func save() {
        func split(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var rules = model.settings.bc100Rules
        rules.excludedOperators = split(operators)
        rules.excludedLinePrefixes = split(prefixes)
        model.settings.bc100Rules = rules
    }
}

struct QuickTagsView: View {
    @Environment(AppModel.self) private var model
    @State private var tags: [QuickTag] = []
    @State private var showAddSheet = false

    var body: some View {
        Form {
            Section {
                ForEach(tags) { tag in
                    HStack(spacing: 12) {
                        IconTile(systemImage: tag.systemImage, color: .brand, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.label).font(.subheadline.weight(.medium))
                            Text(tag.value.map { "\(tag.key) = \($0)" } ?? tag.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indices in
                    tags.remove(atOffsets: indices)
                    save()
                }
                .onMove { indices, destination in
                    tags.move(fromOffsets: indices, toOffset: destination)
                    save()
                }
            } footer: {
                Text("Diese Tags schlagen wir dir beim Einchecken vor. Ohne festen Wert fragen wir dich jedes Mal, z. B. nach deinem Sitzplatz.")
            }
            Section {
                Button {
                    showAddSheet = true
                } label: {
                    IconLabel(title: "Tag hinzufügen", systemImage: "plus.circle.fill", color: .brand)
                }
                .foregroundStyle(.primary)
                Button {
                    tags = QuickTag.defaults
                    save()
                } label: {
                    IconLabel(title: "Standard wiederherstellen", systemImage: "arrow.counterclockwise", color: .gray)
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onAppear { tags = model.settings.quickTags }
        .sheet(isPresented: $showAddSheet) {
            AddQuickTagSheet { newTag in
                tags.append(newTag)
                save()
            }
        }
    }

    private func save() { model.settings.quickTags = tags }
}

struct AddQuickTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var key = ""
    @State private var value = ""
    let onAdd: (QuickTag) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, z. B. Triebzug", text: $label)
                    TextField("Schlüssel, z. B. trwl:seat oder triebzug", text: $key)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Fester Wert (optional)", text: $value)
                } footer: {
                    Text("Ohne Wert fragen wir dich beim Einchecken. Mit Wert reicht ein Tipp.")
                }
            }
            .navigationTitle("Neuer Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") {
                        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
                        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
                        let trimmedValue = value.trimmingCharacters(in: .whitespaces)
                        onAdd(QuickTag(label: trimmedLabel, key: trimmedKey, value: trimmedValue.isEmpty ? nil : trimmedValue))
                        dismiss()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
