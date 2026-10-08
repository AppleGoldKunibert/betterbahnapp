import BetterBahnKit
import SwiftUI

struct SettingsView: View {
    /// Served by the `Cloudflare/worker.mjs` Worker; also the privacy policy URL in App Store Connect.
    static let privacyPolicyURL = URL(string: "https://betterbahn.betterbahn.workers.dev/datenschutz")!

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
                        // The app icon itself (AppLogo is the icon scaled to 56 pt).
                        Image("AppLogo")
                            .resizable()
                            .frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 56 * 0.2237, style: .continuous))
                            .accessibilityHidden(true)
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
                    NavigationLink {
                        TicketsListView()
                    } label: {
                        IconLabel(title: "Gespeicherte Tickets", systemImage: "ticket.fill", color: .brand)
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
                    Toggle(isOn: $settings.liveActivitiesEnabled) {
                        IconLabel(title: "Live-Aktivitäten", systemImage: "bolt.badge.clock.fill", color: .indigo)
                    }
                    .tint(.brand)
                    .onChange(of: settings.liveActivitiesEnabled) { model.syncLiveActivity() }
                } header: {
                    Text("Meine Reisen")
                } footer: {
                    Text("Wir sagen dir Bescheid, wenn ein Zug ausfällt, das Gleis wechselt oder du deinen Anschluss verpasst. Live-Aktivitäten zeigen deine nächste Reise auf dem Sperrbildschirm.")
                }

                Section {
                    Picker(selection: $settings.trainPositionRefresh) {
                        ForEach(TrainPositionRefresh.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    } label: {
                        IconLabel(title: "Aktualisierung", systemImage: "location.fill", color: .brand)
                    }
                } header: {
                    Text("Live-Karte")
                } footer: {
                    Text(trainPositionRefreshFooter)
                }

                Section {
                    Menu {
                        ForEach(TrainSearchKind.allCases, id: \.self) { kind in
                            Toggle(kind.displayName, isOn: Binding {
                                settings.trainSearchKinds.contains(kind)
                            } set: { on in
                                if on { settings.trainSearchKinds.insert(kind) } else { settings.trainSearchKinds.remove(kind) }
                            })
                        }
                    } label: {
                        HStack {
                            IconLabel(title: "Zugarten", systemImage: "tram.fill", color: .brand)
                            Spacer()
                            Text(trainSearchKindsSummary(settings.trainSearchKinds))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(.rect)
                    }
                    .menuActionDismissBehavior(.disabled)
                    .tint(.primary)
                    NavigationLink {
                        TrainSearchCountriesView()
                    } label: {
                        HStack {
                            IconLabel(title: "Länder", systemImage: "globe.europe.africa.fill", color: .teal)
                            Spacer()
                            Text(trainSearchCountriesSummary(settings.trainSearchCountries))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Zugschnellsuche")
                } footer: {
                    Text("Die Suche nach Zugnummer (Zug-Symbol bei Verbindungen, Lupe auf der Karte) zeigt nur diese Zugarten und nur Züge, die durch eines der Länder fahren.")
                }

                Section {
                    Toggle(isOn: $settings.shareTrainStatistics) {
                        IconLabel(title: "Zugdaten für Statistik teilen", systemImage: "chart.bar.fill", color: .teal)
                    }
                    .tint(.brand)
                } header: {
                    Text("Statistik")
                } footer: {
                    Text("Schickt Zugnummer und Fahrt der Regional- und Fernzüge, die du dir ansiehst, an den BetterBahn-Server. Er merkt sich dann Verspätungen, Gleiswechsel, Ausfälle und Wagenreihung dieser Fahrt für spätere Statistiken. Ohne Bezug zu dir oder deinem Standort.")
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
                        Toggle(isOn: $settings.expertIgnoreBoardingRules) {
                            IconLabel(title: "„Nur Ein-/Ausstieg“ ignorieren", systemImage: "arrow.up.arrow.down.circle.fill", color: .teal)
                        }
                        .tint(.brand)
                        Toggle(isOn: $settings.expertRil100) {
                            IconLabel(title: "RIL100-Codes in der Suche", systemImage: "character.textbox", color: .gray)
                        }
                        .tint(.brand)
                    }
                } header: {
                    Text("Für Profis")
                } footer: {
                    Text(settings.expertMode
                         ? "Zusätzliche Funktionen für Vielfahrer. „Nur Ein-/Ausstieg“ ignorieren zeigt in der Suche auch direkte Züge, die laut Fahrplan dort keinen Einstieg oder Ausstieg erlauben. RIL100-Codes zeigt in der Bahnhofssuche die DB-Abkürzung rechts neben dem Bahnhof (z. B. FF); suchen kann man mit „ff“ auch so."
                         : "Zusätzliche Funktionen für Vielfahrer.")
                }

                Section {
                    NavigationLink {
                        DataSourcesView()
                    } label: {
                        IconLabel(title: "Datenquellen", systemImage: "server.rack", color: .gray)
                    }
                    Link(destination: Self.privacyPolicyURL) {
                        IconLabel(title: "Datenschutz", systemImage: "hand.raised.fill", color: .blue)
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Fahrplandaten: [Transitous](https://transitous.org/sources/), Echtzeitdaten: Deutsche Bahn ([DB Timetables](https://developers.deutschebahn.com/db-api-marketplace/apis/product/timetables), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/deed.de)), Karten: [© OpenStreetMap](https://www.openstreetmap.org/copyright), [OpenRailwayMap](https://www.openrailwaymap.org)\n\nBetterBahn ist ein privates Projekt und steht in keiner Verbindung zur Deutschen Bahn AG.")
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

    private var trainPositionRefreshFooter: String {
        switch model.settings.trainPositionRefresh {
        case .off:
            "Karten laden die Positionen der Züge nur einmal beim Öffnen."
        case .automatic:
            "Wie oft Karten die Positionen fahrender Züge neu laden: alle 15 Sekunden, mit mobilen Daten oder im Datensparmodus jede Minute. Häufigeres Aktualisieren kann mehr Daten verbrauchen."
        default:
            "Wie oft Karten die Positionen fahrender Züge neu laden. Häufigeres Aktualisieren kann mehr Daten verbrauchen, vor allem mit mobilen Daten."
        }
    }

    private func trainSearchKindsSummary(_ kinds: Set<TrainSearchKind>) -> String {
        if kinds == Set(TrainSearchKind.allCases) { return "Alle" }
        if kinds == TrainSearchKind.defaults { return "Alle Züge" }
        if kinds.isEmpty { return "Keine" }
        return TrainSearchKind.allCases.filter(kinds.contains).map(\.displayName).joined(separator: ", ")
    }

    private func trainSearchCountriesSummary(_ codes: Set<String>) -> String {
        if codes.isEmpty { return "Überall" }
        let names = TrainSearchCountry.all.filter { codes.contains($0.code) }.map(\.name)
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) Länder"
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
                    if let points = user?.points, user?.pointsEnabled == true {
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
                        // The count keeps growing while a long history is imported page by page.
                        Text("\(model.traewellingTrips.count) Fahrten")
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        if model.isSyncingTraewelling {
                            ProgressView()
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

/// Settings → Zugschnellsuche → Länder: the train search lists only trains running through one of them.
private struct TrainSearchCountriesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Button {
                    settings.trainSearchCountries = []
                } label: {
                    row(title: "Überall", flag: "🌍", selected: settings.trainSearchCountries.isEmpty)
                }
            } footer: {
                Text("Zeigt Züge aus allen Ländern, die bahn.expert kennt.")
            }
            Section {
                ForEach(TrainSearchCountry.all) { country in
                    Button {
                        if settings.trainSearchCountries.contains(country.code) {
                            settings.trainSearchCountries.remove(country.code)
                        } else {
                            settings.trainSearchCountries.insert(country.code)
                        }
                    } label: {
                        row(title: country.name, flag: country.flag,
                            selected: settings.trainSearchCountries.contains(country.code))
                    }
                }
            } footer: {
                Text("Ein Zug wird gezeigt, wenn er in einem der gewählten Länder startet, endet oder hält.")
            }
        }
        .navigationTitle("Länder")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(title: String, flag: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(flag).font(.title3)
            Text(title).foregroundStyle(.primary)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.brand)
            }
        }
        .contentShape(.rect)
    }
}
