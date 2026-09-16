import BetterBahnKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var user: TraewellingUser?
    @State private var isLoggedIn = false
    @State private var clientID = ""
    @State private var dbRestURL = ""

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
                    LabeledContent {
                        TextField("Client-ID", text: $clientID)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(applyClientID)
                    } label: {
                        IconLabel(title: "Client-ID", systemImage: "key.fill", color: .gray)
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
                } header: {
                    Text("Träwelling")
                } footer: {
                    Text("Lege unter traewelling.de/settings/applications eine Anwendung mit der Weiterleitungs-URL betterbahn://oauth an und trage die Client-ID ein.")
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
                    LabeledContent {
                        TextField("URL", text: $dbRestURL)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(applyDBRestURL)
                    } label: {
                        IconLabel(title: "db-rest", systemImage: "server.rack", color: .blue)
                    }
                    HStack {
                        IconLabel(title: "Fallback", systemImage: "point.3.connected.trianglepath.dotted", color: .teal)
                        Spacer()
                        Text("Transitous").foregroundStyle(.secondary)
                    }
                    Button {
                        dbRestURL = DBRestProvider.defaultBaseURL.absoluteString
                        applyDBRestURL()
                    } label: {
                        IconLabel(title: "Standard wiederherstellen", systemImage: "arrow.counterclockwise", color: .gray)
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Datenquellen")
                } footer: {
                    Text("Primär db-rest. Ist der Dienst nicht erreichbar, wechselt die App automatisch zu Transitous.")
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
            .task {
                clientID = model.settings.traewellingClientID
                dbRestURL = model.settings.dbRestBaseURL
                await refreshLogin()
            }
            .onDisappear {
                applyClientID()
                applyDBRestURL()
            }
        }
    }

    private func applyClientID() {
        let trimmed = clientID.trimmingCharacters(in: .whitespaces)
        guard trimmed != model.settings.traewellingClientID else { return }
        model.settings.traewellingClientID = trimmed
        model.applySettings()
    }

    private func applyDBRestURL() {
        let trimmed = dbRestURL.trimmingCharacters(in: .whitespaces)
        guard trimmed != model.settings.dbRestBaseURL, URL(string: trimmed)?.scheme?.hasPrefix("http") == true else { return }
        model.settings.dbRestBaseURL = trimmed
        model.applySettings()
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

#Preview {
    SettingsView()
        .environment(AppModel())
}
