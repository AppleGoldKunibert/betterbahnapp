import AuthenticationServices
import BetterBahnKit
import SwiftUI

struct SettingsView: View {
    /// Served by the `Cloudflare/worker.mjs` Worker; also the privacy policy URL in App Store Connect.
    static let privacyPolicyURL = URL(string: "https://betterbahn.betterbahn.workers.dev/datenschutz")!

    @Environment(AppModel.self) private var model
    @State private var user: TraewellingUser?
    @State private var isLoggedIn = false
    @State private var showClearHistoryConfirmation = false
    @State private var showFollowedCheckinPushConfirmation = false
    @State private var isEnablingFollowedCheckinPush = false
    @State private var followedCheckinPushError: Error?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

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
                        Task { await model.syncCommutePush() }
                    }
                    Toggle(isOn: $settings.exitReminders) {
                        IconLabel(title: "Ans Aussteigen erinnern", systemImage: "bell.badge.fill", color: .red)
                    }
                    .tint(.brand)
                    .onChange(of: settings.exitReminders) { _, enabled in
                        if enabled { Task { await ConnectionNotifier.requestAuthorization() } }
                        model.scheduleExitReminderSync()
                    }
                    if settings.exitReminders {
                        Picker(selection: $settings.exitReminderLead) {
                            ForEach(ExitReminderLead.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        } label: {
                            IconLabel(title: "Erinnerung", systemImage: "clock.fill", color: .red)
                        }
                        .onChange(of: settings.exitReminderLead) { model.scheduleExitReminderSync() }
                    }
                    Toggle(isOn: $settings.liveActivitiesEnabled) {
                        IconLabel(title: "Live-Aktivitäten", systemImage: "bolt.badge.clock.fill", color: .indigo)
                    }
                    .tint(.brand)
                    .onChange(of: settings.liveActivitiesEnabled) { model.syncLiveActivity() }
                    if settings.liveActivitiesEnabled {
                        Toggle(isOn: $settings.liveActivityServerUpdates) {
                            IconLabel(title: "Live-Aktivität über Server aktualisieren", systemImage: "arrow.trianglehead.2.clockwise",
                                      color: .indigo)
                        }
                        .tint(.brand)
                        .onChange(of: settings.liveActivityServerUpdates) {
                            // Whether an activity gets updates from our server is fixed when it starts.
                            Task {
                                await model.liveActivities.restart()
                                model.syncLiveActivity()
                            }
                        }
                    }
                    NavigationLink {
                        RegularTripsView()
                    } label: {
                        IconLabel(title: "Regelmäßige Fahrten", systemImage: "repeat", color: .brand)
                    }
                } header: {
                    Text("Meine Reisen")
                } footer: {
                    Text(settings.liveActivitiesEnabled
                         ? "Wir sagen dir Bescheid bei Ausfällen, Gleiswechseln und verpassten Anschlüssen – und kurz bevor du aussteigen musst. Über unseren Server zeigt die Live-Aktivität auch bei geschlossener App aktuelle Zeiten und Gleise. Er bekommt dafür deine Reise bis zur Ankunft."
                         : "Wir sagen dir Bescheid bei Ausfällen, Gleiswechseln und verpassten Anschlüssen – und kurz bevor du aussteigen musst.")
                }

                Section {
                    Picker(selection: Binding(get: { settings.calendarAccess ?? .full },
                                              set: { settings.calendarAccess = $0 })) {
                        ForEach(CalendarAccessMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    } label: {
                        IconLabel(title: "Zugriff", systemImage: "calendar", color: .red)
                    }
                    .onChange(of: settings.calendarAccess) { _, mode in
                        guard let mode, mode == .full || settings.calendarAutoAdd != .off else { return }
                        Task {
                            _ = await model.requestCalendarAccess(mode)
                            model.scheduleCalendarSync(after: .zero)
                        }
                    }
                    if settings.calendarAccess == .full {
                        CalendarChoiceRow()
                    }
                    Picker(selection: $settings.calendarAutoAdd) {
                        ForEach(CalendarAutoAdd.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    } label: {
                        IconLabel(title: "Automatisch", systemImage: "calendar.badge.clock", color: .red)
                    }
                    .onChange(of: settings.calendarAutoAdd) { _, autoAdd in
                        guard autoAdd != .off else { return }
                        // Asked here, never in the background: the access the first choice in this section stands for.
                        if settings.calendarAccess == nil { settings.calendarAccess = .full }
                        Task {
                            _ = await model.requestCalendarAccess(settings.calendarAccess ?? .full)
                            model.scheduleCalendarSync(after: .zero)
                        }
                    }
                } header: {
                    Text("Kalender")
                } footer: {
                    Text("Mit vollem Zugriff bleiben die Termine deiner Reisen aktuell, auch bei Verspätungen und Gleiswechseln, und verschwinden mit der Reise. Mit „Nur hinzufügen“ wird jeder Termin einmal in deinen Standardkalender eingetragen. Automatisch kommt jede gespeicherte Reise einmal in den Kalender, beim Speichern oder erst bei der Abfahrt.")
                }

                Section {
                    Picker(selection: $settings.stationFlagMode) {
                        Text("Aus").tag(StationFlagMode.off)
                        Text("Nur Ausland").tag(StationFlagMode.foreignOnly)
                        Text("An").tag(StationFlagMode.always)
                    } label: {
                        IconLabel(title: "Flagge", systemImage: "flag.fill", color: .brand)
                    }
                } header: {
                    Text("Bahnhofssuche")
                } footer: {
                    Text("Zeigt in der Suche die Flagge vor dem Bahnhof, auf Wunsch nur bei Bahnhöfen im Ausland. Mit einer Flagge hinter dem Namen siehst du nur Bahnhöfe aus diesem Land.")
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
                    Text("Die Zugsuche zeigt nur diese Zugarten und Länder.")
                }

                Section {
                    Toggle(isOn: $settings.showTrainStatistics) {
                        IconLabel(title: "Zugstatistik anzeigen", systemImage: "chart.bar.fill", color: .teal)
                    }
                    .tint(.brand)
                } header: {
                    Text("Statistik")
                } footer: {
                    Text("Zeigt dir, wie pünktlich ein Zug in den letzten 30 Tagen war und wie oft er ausfiel oder das Gleis wechselte.")
                }

                Section {
                    Toggle(isOn: $settings.showWeather) {
                        IconLabel(title: "Wetter am Ziel", systemImage: "cloud.sun.fill", color: .orange)
                    }
                    .tint(.brand)
                } header: {
                    Text("Wetter")
                } footer: {
                    Text("Zeigt in der Reise das Wetter bei Ankunft und bei längeren Umstiegen. Dafür wird nur der Bahnhof verschickt, nie dein Standort.")
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
                            IconLabel(title: "Träwelling", systemImage: "checkmark.seal.fill", color: .brand,
                                      subtitle: "Bei Träwelling in Züge einchecken.")
                        }
                        .tint(.brand)
                        Toggle(isOn: $settings.expertEditJourney) {
                            IconLabel(title: "Reise bearbeiten", systemImage: "pencil", color: .orange,
                                      subtitle: "Reisen ändern und ab einem Halt neu planen.")
                        }
                        .tint(.brand)
                        Toggle(isOn: $settings.expertTrainChoice) {
                            IconLabel(title: "Bestimmten Zug wählen", systemImage: "number", color: .purple,
                                      subtitle: "Einen bestimmten Zug in die Reise übernehmen.")
                        }
                        .tint(.brand)
                        Toggle(isOn: $settings.expertIgnoreBoardingRules) {
                            IconLabel(title: "„Nur Ein-/Ausstieg“ ignorieren", systemImage: "arrow.up.arrow.down.circle.fill", color: .teal,
                                      subtitle: "Auch Züge, die nur zum Ein- oder Aussteigen halten.")
                        }
                        .tint(.brand)
                        Toggle(isOn: $settings.expertRil100) {
                            IconLabel(title: "RIL100-Codes in der Suche", systemImage: "character.textbox", color: .gray,
                                      subtitle: "Kürzel wie „FF“ zeigen und danach suchen.")
                        }
                        .tint(.brand)
                    }
                } header: {
                    Text("Für Profis")
                } footer: {
                    Text("Zusätzliche Funktionen für Vielfahrer.")
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
            .closesMenusOnScroll()
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
        default:
            "Wie oft die Live-Position aktualisiert wird. Öfter verbraucht mehr Daten."
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
                        await model.disableFollowedCheckinPush()
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
            if isLoggedIn {
                Toggle(isOn: Binding {
                    settings.notifyFollowedCheckins || isEnablingFollowedCheckinPush
                } set: { on in
                    followedCheckinPushError = nil
                    if on {
                        showFollowedCheckinPushConfirmation = true
                    } else {
                        Task { await model.disableFollowedCheckinPush() }
                    }
                }) {
                    HStack {
                        IconLabel(title: "Check-ins von Gefolgten melden", systemImage: "bell.badge.fill", color: .orange)
                        if isEnablingFollowedCheckinPush {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .tint(.brand)
                .disabled(isEnablingFollowedCheckinPush)
                .alert("Dieses Feature benötigt eine erneute Anmeldung mit Träwelling. Möchtest du fortfahren?",
                       isPresented: $showFollowedCheckinPushConfirmation) {
                    Button("Fortfahren") { enableFollowedCheckinPush() }
                    Button("Abbrechen", role: .cancel) {}
                }
                if let followedCheckinPushError {
                    ErrorBanner(error: followedCheckinPushError)
                }
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
        } footer: {
            if isLoggedIn, settings.notifyFollowedCheckins {
                Text("Unser Server schaut alle 2 Minuten nach neuen Check-ins. Dabei wird nichts gespeichert.")
            } else if isLoggedIn, model.followedCheckinPushEnded {
                Text("Träwelling hat die Anmeldung für die Meldungen beendet. Zum Weitermachen wieder einschalten.")
            }
        }
    }

    /// Signs in with Träwelling once more for the push Worker (#266), in the same browser session as the
    /// app's own login; cancelling it leaves the setting off.
    private func enableFollowedCheckinPush() {
        isEnablingFollowedCheckinPush = true
        Task {
            defer { isEnablingFollowedCheckinPush = false }
            do {
                try await model.enableFollowedCheckinPush { url, scheme in
                    try await webAuthenticationSession.authenticate(using: url, callback: .customScheme(scheme),
                                                                    preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
                }
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            } catch {
                followedCheckinPushError = error
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
                Text("Diese Tags schlagen wir dir beim Einchecken vor.")
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
