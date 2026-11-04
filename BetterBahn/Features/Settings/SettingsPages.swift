import BetterBahnKit
import SwiftUI

// The menus of Settings (#547): each groups a few related settings on a page of its own.

extension View {
    /// A settings menu's page: the design's background, menus closing on scroll and a small title.
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        designedForm()
            .closesMenusOnScroll()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Ticket & Reise: ticket and class, bike, step-free travel and regular trips.
struct TicketTravelSettingsView: View {
    var body: some View {
        Form {
            TicketSettingsSection()
            BikeSettingsSection()
            StepFreeSettingsSection()
            Section {
                NavigationLink {
                    RegularTripsView()
                } label: {
                    IconLabel(title: String(localized: "Regelmäßige Fahrten"), systemImage: "repeat", color: .settingsIcon)
                }
            } footer: {
                Text("Für Strecken, die du oft fährst: Wir fragen kurz vor der Abfahrt, ob du heute fährst.")
            }
        }
        .settingsPage("Ticket & Reise")
    }
}

/// Settings › Mitteilungen: warnings, exit reminders and the Live Activity.
struct NotificationSettingsView: View {
    var body: some View {
        Form {
            NotificationSettingsSection()
        }
        .settingsPage("Mitteilungen")
    }
}

/// Settings › Kalender.
struct CalendarSettingsView: View {
    var body: some View {
        Form {
            CalendarSettingsSection()
        }
        .settingsPage("Kalender")
    }
}

/// Settings › Suche & Karten: station search, train search and the maps.
struct SearchMapSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker(selection: $settings.stationFlagMode) {
                    Text("Aus").tag(StationFlagMode.off)
                    Text("Nur Ausland").tag(StationFlagMode.foreignOnly)
                    Text("An").tag(StationFlagMode.always)
                } label: {
                    IconLabel(title: String(localized: "Flagge"), systemImage: "flag.fill", color: .settingsIcon)
                }
            } header: {
                FormHeader("Bahnhofssuche")
            } footer: {
                Text("Zeigt in der Suche die Flagge vor dem Bahnhof, auf Wunsch nur bei Bahnhöfen im Ausland. Mit einer Flagge hinter dem Namen siehst du nur Bahnhöfe aus diesem Land.")
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
                        IconLabel(title: String(localized: "Zugarten"), systemImage: "tram.fill", color: .settingsIcon)
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
                        IconLabel(title: String(localized: "Länder"), systemImage: "globe.europe.africa.fill", color: .settingsIcon)
                        Spacer()
                        Text(trainSearchCountriesSummary(settings.trainSearchCountries))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                FormHeader("Zugschnellsuche")
            } footer: {
                Text("Die Zugsuche zeigt nur diese Zugarten und Länder.")
            }

            Section {
                Picker(selection: $settings.trainPositionRefresh) {
                    ForEach(TrainPositionRefresh.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    IconLabel(title: String(localized: "Aktualisierung"), systemImage: "location.fill", color: .settingsIcon)
                }
            } header: {
                FormHeader("Live-Karte")
            } footer: {
                Text(trainPositionRefreshFooter)
            }

            Section {
                Toggle(isOn: $settings.showOtherTrains) {
                    IconLabel(title: String(localized: "Andere Züge zeigen"), systemImage: "tram.fill", color: .gray)
                }
                if settings.showOtherTrains {
                    Toggle(isOn: $settings.otherTrainsOnMobileData) {
                        IconLabel(title: String(localized: "Strecken über Mobilfunk laden"), systemImage: "antenna.radiowaves.left.and.right",
                                  color: .gray)
                    }
                }
            } footer: {
                Text("Zeigt auf den Karten auch die anderen fahrenden Züge. Über Mobilfunk kann das einige MB pro Karte kosten.")
            }
        }
        .settingsPage("Suche & Karten")
    }

    private var trainPositionRefreshFooter: String {
        switch model.settings.trainPositionRefresh {
        case .off:
            String(localized: "Karten laden die Positionen der Züge nur einmal beim Öffnen.")
        default:
            String(localized: "Wie oft die Live-Position aktualisiert wird. Öfter verbraucht mehr Daten.")
        }
    }

    private func trainSearchKindsSummary(_ kinds: Set<TrainSearchKind>) -> String {
        if kinds == Set(TrainSearchKind.allCases) { return String(localized: "Alle") }
        if kinds == TrainSearchKind.defaults { return String(localized: "Alle Züge") }
        if kinds.isEmpty { return String(localized: "Keine") }
        return TrainSearchKind.allCases.filter(kinds.contains).map(\.displayName).joined(separator: ", ")
    }

    private func trainSearchCountriesSummary(_ codes: Set<String>) -> String {
        if codes.isEmpty { return String(localized: "Überall") }
        let names = TrainSearchCountry.all.filter { codes.contains($0.code) }.map(\.name)
        return names.count <= 2 ? names.joined(separator: ", ") : String(localized: "\(names.count) Länder")
    }
}

/// Settings › Zusatzinfos: what journeys show besides the trains.
struct DisplaySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: $settings.showTrainStatistics) {
                    IconLabel(title: String(localized: "Zugstatistik anzeigen"), systemImage: "chart.bar.fill", color: .settingsIcon)
                }
                .tint(.brandText)
            } header: {
                FormHeader("Statistik")
            } footer: {
                Text("Zeigt dir, wie pünktlich ein Zug in den letzten 30 Tagen war und wie oft er ausfiel oder das Gleis wechselte.")
            }

            Section {
                Toggle(isOn: $settings.showWeather) {
                    IconLabel(title: String(localized: "Wetter am Ziel"), systemImage: "cloud.sun.fill", color: .settingsIcon)
                }
                .tint(.brandText)
            } header: {
                FormHeader("Wetter")
            } footer: {
                Text("Zeigt in der Reise das Wetter bei Ankunft und bei längeren Umstiegen. Dafür wird nur der Bahnhof verschickt, nie dein Standort.")
            }
        }
        .settingsPage("Zusatzinfos")
    }
}

/// Settings › Für Profis: the expert features, each switched on by itself.
struct ExpertSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: $settings.expertMode.animation()) {
                    IconLabel(title: String(localized: "Expertenmodus"), systemImage: "wand.and.stars", color: .settingsIcon)
                }
                .tint(.brandText)
                if settings.expertMode {
                    Toggle(isOn: $settings.expertTraewelling) {
                        IconLabel(title: String(localized: "Träwelling"), systemImage: "checkmark.seal.fill", color: .settingsIcon,
                                  subtitle: String(localized: "Bei Träwelling in Züge einchecken."))
                    }
                    .tint(.brandText)
                    Toggle(isOn: $settings.expertEditJourney) {
                        IconLabel(title: String(localized: "Reise bearbeiten"), systemImage: "pencil", color: .settingsIcon,
                                  subtitle: String(localized: "Reisen ändern und ab einem Halt neu planen."))
                    }
                    .tint(.brandText)
                    Toggle(isOn: $settings.expertTrainChoice) {
                        IconLabel(title: String(localized: "Bestimmten Zug wählen"), systemImage: "number", color: .settingsIcon,
                                  subtitle: String(localized: "Einen bestimmten Zug in die Reise übernehmen."))
                    }
                    .tint(.brandText)
                    Toggle(isOn: $settings.expertIgnoreBoardingRules) {
                        IconLabel(title: String(localized: "„Nur Ein-/Ausstieg“ ignorieren"), systemImage: "arrow.up.arrow.down.circle.fill", color: .settingsIcon,
                                  subtitle: String(localized: "Auch Züge, die nur zum Ein- oder Aussteigen halten."))
                    }
                    .tint(.brandText)
                    Toggle(isOn: $settings.expertRil100) {
                        IconLabel(title: String(localized: "RIL100-Codes in der Suche"), systemImage: "character.textbox", color: .settingsIcon,
                                  subtitle: String(localized: "Kürzel wie „FF“ zeigen und danach suchen."))
                    }
                    .tint(.brandText)
                }
            } footer: {
                Text("Zusätzliche Funktionen für Vielfahrer.")
            }
        }
        .settingsPage("Für Profis")
    }
}

/// Settings › Träwelling: login, map import, notifications, visibility and tags. Only while the expert
/// feature is on.
struct TraewellingSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appDesign) private var design
    @State private var user: TraewellingUser?
    @State private var isLoggedIn = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                if isLoggedIn {
                    HStack(spacing: 12) {
                        IconTile(systemImage: "person.crop.circle.badge.checkmark", color: .punctual)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user?.displayName ?? String(localized: "Angemeldet")).font(.body.weight(.semibold))
                                .fontDesign(design == .fahrkarte ? .rounded : nil)
                            if let user {
                                Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let points = user?.points, user?.pointsEnabled == true {
                            InfoChip(text: "\(points)", systemImage: "sparkles", tint: .brandText)
                        }
                    }
                    Button(role: .destructive) {
                        Task {
                            await model.disableCheckinPush()
                            await model.traewelling.logout()
                            await refreshLogin()
                        }
                    } label: {
                        IconLabel(title: String(localized: "Abmelden"), systemImage: "rectangle.portrait.and.arrow.right", color: .heavyDelay)
                    }
                } else {
                    TraewellingLoginButton { Task { await refreshLogin() } }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                Toggle(isOn: $settings.syncTraewellingToMap) {
                    IconLabel(title: String(localized: "Fahrten auf der Karte zeigen"), systemImage: "map.fill", color: .settingsIcon)
                }
                .tint(.brandText)
                if isLoggedIn, settings.syncTraewellingToMap {
                    Button {
                        Task { await model.syncTraewelling(force: true) }
                    } label: {
                        HStack {
                            IconLabel(title: String(localized: "Jetzt synchronisieren"), systemImage: "arrow.triangle.2.circlepath", color: .settingsIcon)
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
                    NavigationLink {
                        CheckinNotificationsView()
                    } label: {
                        IconLabel(title: String(localized: "Mitteilungen"), systemImage: "bell.badge.fill", color: .settingsIcon)
                    }
                }
                Picker(selection: $settings.traewellingVisibility) {
                    ForEach(TraewellingVisibility.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    IconLabel(title: String(localized: "Sichtbarkeit"), systemImage: "eye.fill", color: .settingsIcon)
                }
                NavigationLink {
                    QuickTagsView()
                } label: {
                    IconLabel(title: String(localized: "Tags"), systemImage: "tag.fill", color: .settingsIcon)
                }
            }
        }
        .settingsPage("Träwelling")
        .task { await refreshLogin() }
    }

    private func refreshLogin() async {
        isLoggedIn = await model.traewelling.isLoggedIn
        user = isLoggedIn ? try? await model.traewelling.currentUser() : nil
    }
}

/// Settings › Suche & Karten › Länder: the train search lists only trains running through one of them.
private struct TrainSearchCountriesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Button {
                    settings.trainSearchCountries = []
                } label: {
                    row(title: String(localized: "Überall"), flag: "🌍", selected: settings.trainSearchCountries.isEmpty)
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
        .designedForm()
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
                    .foregroundStyle(Color.brandText)
            }
        }
        .contentShape(.rect)
    }
}
