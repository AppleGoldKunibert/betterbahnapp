import BetterBahnKit
import SwiftUI

struct SettingsView: View {
    /// Served by the `Cloudflare/worker.mjs` Worker; also the privacy policy URL in App Store Connect.
    static let privacyPolicyURL = URL(string: "https://betterbahn.betterbahn.workers.dev/datenschutz")!

    @Environment(AppModel.self) private var model
    @State private var traewellingUser: TraewellingUser?
    @State private var showClearHistoryConfirmation = false
    @State private var showQuickSetup = false
    @Environment(\.appDesign) private var design

    /// The accent color's name, or "Eigene Farbe".
    private var accentName: String {
        switch Theme.shared.accent {
        case .preset(let preset): preset.displayName
        case .custom: String(localized: "Eigene Farbe")
        }
    }

    var body: some View {
        let settings = model.settings
        SplitNavigationView {
            Form {
                Section {
                    HStack(spacing: 16) {
                        // The app icon in the picked accent color.
                        AppLogoView(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BetterBahn")
                                .font(design == .fahrkarte ? .title2.weight(.heavy) : .title3.weight(.bold))
                                .fontDesign(design == .fahrkarte ? .rounded : nil)
                            Text("Bahnfahren, aber besser.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)

                    Button {
                        showQuickSetup = true
                    } label: {
                        HStack {
                            IconLabel(title: String(localized: "Schnelleinrichtung"), systemImage: "wand.and.sparkles",
                                      color: .brandText,
                                      subtitle: String(localized: "Die wichtigsten Einstellungen in \(QuickSetupStep.count) Schritten."))
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    menuRow("Design", systemImage: "paintpalette.fill", color: .brandText,
                            value: "\(Theme.shared.design.displayName) · \(accentName)") {
                        DesignSettingsView()
                    }
                }

                Section {
                    menuRow("Ticket & Reise", systemImage: settings.ticketType.symbolName, color: .settingsIcon,
                            value: "\(settings.ticketType.shortName) · \(settings.travelClass.displayName)") {
                        TicketTravelSettingsView()
                    }
                    menuRow("Mitteilungen", systemImage: "bell.badge.fill", color: .settingsIcon,
                            value: notificationsOn ? String(localized: "An") : String(localized: "Aus")) {
                        NotificationSettingsView()
                    }
                    menuRow("Kalender", systemImage: "calendar", color: .settingsIcon,
                            value: settings.calendarAutoAdd == .off ? nil : String(localized: "Automatisch")) {
                        CalendarSettingsView()
                    }
                    menuRow("Suche & Karten", systemImage: "map.fill", color: .settingsIcon) {
                        SearchMapSettingsView()
                    }
                    menuRow("Zusatzinfos", systemImage: "info.circle.fill", color: .settingsIcon) {
                        DisplaySettingsView()
                    }
                }

                Section {
                    if settings.traewellingEnabled {
                        menuRow("Träwelling", systemImage: "checkmark.seal.fill", color: .settingsIcon,
                                value: traewellingUser.map { "@\($0.username)" }) {
                            TraewellingSettingsView()
                        }
                    }
                    menuRow("Für Profis", systemImage: "wand.and.stars", color: .settingsIcon,
                            value: settings.expertMode ? String(localized: "An") : String(localized: "Aus")) {
                        ExpertSettingsView()
                    }
                }

                Section {
                    NavigationLink {
                        DataSourcesView()
                    } label: {
                        IconLabel(title: String(localized: "Datenquellen"), systemImage: "server.rack", color: .settingsIcon)
                    }
                    Link(destination: Self.privacyPolicyURL) {
                        IconLabel(title: String(localized: "Datenschutz"), systemImage: "hand.raised.fill", color: .settingsIcon)
                    }
                    .foregroundStyle(.primary)
                    Button(role: .destructive) {
                        showClearHistoryConfirmation = true
                    } label: {
                        IconLabel(title: String(localized: "Suchverlauf löschen"), systemImage: "clock.arrow.circlepath", color: .heavyDelay)
                    }
                } footer: {
                    Text("Fahrplandaten: [Transitous](https://transitous.org/sources/), Echtzeitdaten: Deutsche Bahn ([DB Timetables](https://developers.deutschebahn.com/db-api-marketplace/apis/product/timetables), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/deed.de)), Karten: [© OpenStreetMap](https://www.openstreetmap.org/copyright), [OpenRailwayMap](https://www.openrailwaymap.org)\n\nBetterBahn ist ein privates Projekt und steht in keiner Verbindung zur Deutschen Bahn AG.")
                }

                Section {
                    menuRow("Extra-Features", systemImage: "puzzlepiece.extension.fill", color: .settingsIcon,
                            value: settings.extraAlternativeDestination ? String(localized: "An") : String(localized: "Aus")) {
                        ExtraFeaturesSettingsView()
                    }
                }
            }
            .designedForm()
            .navigationTitle("Einstellungen")
            // Back from the Träwelling page, after logging in or out there.
            .onAppear { Task { await refreshTraewellingUser() } }
            .onChange(of: settings.traewellingEnabled) { Task { await refreshTraewellingUser() } }
            .sheet(isPresented: $showQuickSetup) {
                QuickSetupView(welcome: false)
            }
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
        } placeholder: {
            SplitPlaceholder(title: String(localized: "Einstellungen"), systemImage: "gearshape",
                             message: String(localized: "Wähl links einen Bereich."))
        }
    }

    /// Whether any notification about saved journeys is on.
    private var notificationsOn: Bool {
        let settings = model.settings
        return settings.connectionWarnings || settings.exitReminders
            || (settings.liveActivitiesEnabled && LiveActivityManager.isSupported)
    }

    /// A menu's row: its symbol and name, and what is set in it on the right.
    private func menuRow<Destination: View>(_ title: LocalizedStringKey, systemImage: String, color: Color, value: String? = nil,
                                            @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            LabeledContent {
                if let value {
                    Text(value).lineLimit(1)
                }
            } label: {
                Label {
                    Text(title)
                } icon: {
                    IconTile(systemImage: systemImage, color: color, size: 28)
                }
            }
        }
    }

    private func refreshTraewellingUser() async {
        guard model.settings.traewellingEnabled, await model.traewelling.isLoggedIn else {
            traewellingUser = nil
            return
        }
        if traewellingUser == nil {
            traewellingUser = try? await model.traewelling.currentUser()
        }
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
                    IconTile(systemImage: "info.circle.fill", color: .settingsIcon)
                        .accessibilityHidden(true)
                    Text("Die BahnCard 100 gilt nicht bei allen Anbietern. Hier kannst du die Liste anpassen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Anbieter", text: $operators, axis: .vertical)
            } header: {
                FormHeader("Anbieter (mit Komma trennen)")
            } footer: {
                Text("Züge dieser Anbieter werden ausgeblendet.")
            }
            Section {
                TextField("Präfixe", text: $prefixes, axis: .vertical)
            } header: {
                FormHeader("Zugnamen, die beginnen mit (mit Komma trennen)")
            }
            Section {
                Button {
                    load(.default)
                    save()
                } label: {
                    IconLabel(title: String(localized: "Standard wiederherstellen"), systemImage: "arrow.counterclockwise", color: .settingsIcon)
                }
                .foregroundStyle(.primary)
            }
        }
        .designedForm()
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
                        IconTile(systemImage: tag.systemImage, color: .settingsIcon, size: 28)
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
                    IconLabel(title: String(localized: "Tag hinzufügen"), systemImage: "plus.circle.fill", color: .settingsIcon)
                }
                .foregroundStyle(.primary)
                Button {
                    tags = QuickTag.defaults
                    save()
                } label: {
                    IconLabel(title: String(localized: "Standard wiederherstellen"), systemImage: "arrow.counterclockwise", color: .settingsIcon)
                }
                .foregroundStyle(.primary)
            }
        }
        .designedForm()
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
            .designedForm()
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
