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

                Section {
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
                        IconLabel(title: "Fahrten in Karte übernehmen", systemImage: "map.fill", color: .teal)
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

                Section {
                    Toggle(isOn: $settings.onlyBC100ByDefault) {
                        IconLabel(title: "Standardmäßig nur BC100", systemImage: "creditcard.fill", color: .brand)
                    }
                    .tint(.brand)
                    NavigationLink {
                        BC100RulesView()
                    } label: {
                        IconLabel(title: "Ausgeschlossene Betreiber", systemImage: "nosign", color: .orange)
                    }
                } header: {
                    Text("BahnCard 100")
                }

                Section {
                    LabeledContent("Hauptdatenquelle", value: "Transitous")
                    LabeledContent("Stationssuche bei Ausfall", value: "bahn.de")
                    Link("Transitous-Datenquellen", destination: URL(string: "https://transitous.org/sources/")!)
                    Link("© OpenStreetMap-Mitwirkende", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                } header: {
                    Text("Datenquellen")
                } footer: {
                    Text("Verbindungen, Bahnhofstafeln und Fahrtverläufe kommen von Transitous. Echtzeitdaten hängen von den jeweiligen Verkehrsunternehmen ab.")
                }

                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        IconLabel(title: "Erweiterte Einstellungen", systemImage: "gearshape.2.fill", color: .gray)
                    }
                }

                Section {
                    Toggle(isOn: $settings.connectionWarnings) {
                        IconLabel(title: "Warnen, wenn Anschluss platzt", systemImage: "exclamationmark.triangle.fill", color: .orange)
                    }
                    .tint(.brand)
                    .onChange(of: settings.connectionWarnings) { _, enabled in
                        if enabled { Task { await ConnectionNotifier.requestAuthorization() } }
                    }
                } header: {
                    Text("Gespeicherte Reisen")
                } footer: {
                    Text("Gespeicherte Reisen der nächsten 24 Stunden werden mit Echtzeitdaten aktualisiert. Klappt ein Umstieg nicht mehr oder fällt ein Zug aus, bekommst du eine Mitteilung und kannst eine Alternative wählen.")
                }

                Section {
                    Button(role: .destructive) {
                        showClearHistoryConfirmation = true
                    } label: {
                        IconLabel(title: "Suchverlauf löschen", systemImage: "clock.arrow.circlepath", color: .heavyDelay)
                    }
                } header: {
                    Text("Verlauf")
                } footer: {
                    Text("Löscht deine zuletzt gesuchten Bahnhöfe und Verbindungen. Favoriten, gespeicherte Reisen und deine Anmeldung bleiben erhalten.")
                }

                Section {
                    Button {
                        Task { await model.liveActivities.endAll() }
                    } label: {
                        IconLabel(title: "Alle Live Activities beenden", systemImage: "stop.circle.fill", color: .indigo)
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Live Activity")
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
                    Text("Die BahnCard 100 gilt in DB-Zügen und im Nahverkehr, aber nicht bei unabhängigen Fernverkehrsanbietern. Passe die Liste an, falls etwas fehlt.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Betreiber", text: $operators, axis: .vertical)
            } header: {
                Label("Betreiber (kommagetrennt)", systemImage: "building.2.fill")
            } footer: {
                Text("Züge, deren Betreibername einen dieser Begriffe enthält, werden ausgeblendet.")
            }
            Section {
                TextField("Präfixe", text: $prefixes, axis: .vertical)
            } header: {
                Label("Linien-Präfixe (kommagetrennt)", systemImage: "textformat.abc")
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
                Text("Diese Tags werden dir beim Einchecken als Schnellauswahl vorgeschlagen. Tags ohne festen Wert fragen beim Einchecken nach einem Wert, z. B. für eine Sitzplatznummer.")
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
                    Text("Lass den Wert leer, um beim Einchecken danach gefragt zu werden. Mit einem festen Wert wird der Tag durch Antippen direkt gesetzt, z. B. Schlüssel „triebzug“ mit Wert „Ja“.")
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

/// Settings that ship with a working default and only need touching to override it.
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var timetablesClientID = ""
    @State private var timetablesApiKey = ""

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    TextField("Standard", text: $timetablesClientID)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(applyTimetablesCredentials)
                } label: {
                    IconLabel(title: "Client-ID", systemImage: "key.fill", color: .gray)
                }
                LabeledContent {
                    SecureField("Standard", text: $timetablesApiKey)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(applyTimetablesCredentials)
                } label: {
                    IconLabel(title: "API-Key", systemImage: "lock.fill", color: .gray)
                }
                Link("Eigene Zugangsdaten auf developers.deutschebahn.com beantragen",
                     destination: URL(string: "https://developers.deutschebahn.com/db-api-marketplace/apis/product/timetables")!)
            } header: {
                Text("DB-Echtzeitdaten")
            } footer: {
                Text("BetterBahn gleicht Verspätungen und Gleisänderungen bereits standardmäßig zusätzlich mit der offiziellen DB-Timetables-API ab, nützlich wenn Transitous sie verspätet oder gar nicht meldet. Trage hier nur eigene Zugangsdaten ein, wenn du den mitgelieferten Zugang ersetzen möchtest.")
            }
        }
        .navigationTitle("Erweiterte Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            timetablesClientID = model.timetablesCredentials?.clientID ?? ""
            timetablesApiKey = model.timetablesCredentials?.apiKey ?? ""
        }
        .onDisappear(perform: applyTimetablesCredentials)
    }

    private func applyTimetablesCredentials() {
        let trimmedID = timetablesClientID.trimmingCharacters(in: .whitespaces)
        let trimmedKey = timetablesApiKey.trimmingCharacters(in: .whitespaces)
        guard trimmedID != (model.timetablesCredentials?.clientID ?? "") || trimmedKey != (model.timetablesCredentials?.apiKey ?? "") else { return }
        model.updateTimetablesCredentials(clientID: trimmedID, apiKey: trimmedKey)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
