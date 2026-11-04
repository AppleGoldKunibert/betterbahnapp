import BetterBahnKit
import SwiftUI

// The settings' sections, each with what changing it sets off (asking for notifications, rescheduling
// reminders, …), so the menus in Settings and the quick setup (#547) behave the same.

/// Ticket, travel class, the "only valid trains" filter, BahnCard 100 rules and saved tickets.
struct TicketSettingsSection: View {
    @Environment(AppModel.self) private var model
    /// The quick setup leaves out the rows that open further pages.
    var showsLinks = true

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Picker(selection: $settings.ticketType) {
                ForEach(TicketType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                IconLabel(title: String(localized: "Mein Ticket"), systemImage: settings.ticketType.symbolName, color: .brandText)
            }
            Picker(selection: $settings.travelClass) {
                ForEach(TravelClass.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                IconLabel(title: String(localized: "Reiseklasse"), systemImage: "person.2.fill", color: .settingsIcon)
            }
            Toggle(isOn: $settings.ticketFilterByDefault) {
                IconLabel(title: String(localized: "Nur passende Züge zeigen"),
                          systemImage: "line.3.horizontal.decrease.circle.fill", color: .settingsIcon)
            }
            .tint(.brandText)
            if showsLinks {
                if settings.ticketType == .bahnCard100 {
                    NavigationLink {
                        BC100RulesView()
                    } label: {
                        IconLabel(title: String(localized: "Ausgeschlossene Anbieter"), systemImage: "nosign", color: .settingsIcon)
                    }
                }
                NavigationLink {
                    TicketsListView()
                } label: {
                    IconLabel(title: String(localized: "Gespeicherte Tickets"), systemImage: "ticket.fill", color: .settingsIcon)
                }
            }
        } header: {
            FormHeader("Ticket")
        } footer: {
            Text(settings.ticketType == .deutschlandticket
                 ? "Blendet Fernzüge wie ICE und IC aus, in denen das Deutschlandticket nicht gilt. Die erwartete Auslastung wird für deine Reiseklasse gezeigt."
                 : "Blendet Züge aus, in denen die BahnCard 100 nicht gilt, z. B. FlixTrain. Die erwartete Auslastung wird für deine Reiseklasse gezeigt.")
        }
    }
}

/// Whether a bike comes along (#398).
struct BikeSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Picker(selection: $settings.bikeOption) {
                ForEach(BikeOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                IconLabel(title: String(localized: "Fahrrad"), systemImage: "bicycle", color: .settingsIcon)
            }
        } footer: {
            Text(settings.bikeOption == .hidden
                 ? "Mit Klapprad oder Fahrrad zeigt die Suche, wo es mitkommt und ob du eine Reservierung oder Fahrradkarte brauchst."
                 : "In der Suche schaltest du ein, ob es diesmal mitkommt.")
        }
    }
}

/// "Stufenfrei reisen" (#486).
struct StepFreeSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle(isOn: $settings.stepFree) {
                IconLabel(title: String(localized: "Stufenfrei reisen"), systemImage: "figure.roll", color: .settingsIcon)
            }
            .tint(.brandText)
            .onChange(of: settings.stepFree) { _, enabled in
                if enabled { Task { await ConnectionNotifier.requestAuthorization() } }
                model.scheduleExitReminderSync()
            }
        } footer: {
            Text("Die Suche zeigt, wo ein Aufzug auf deinem Weg außer Betrieb ist. Für gespeicherte Reisen bekommst du dann eine Mitteilung.")
        }
    }
}

/// Warnings about saved journeys, exit reminders and the Live Activity.
struct NotificationSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle(isOn: $settings.connectionWarnings) {
                IconLabel(title: String(localized: "Bei Problemen benachrichtigen"), systemImage: "exclamationmark.triangle.fill", color: .settingsIcon)
            }
            .tint(.brandText)
            .onChange(of: settings.connectionWarnings) { _, enabled in
                if enabled { Task { await ConnectionNotifier.requestAuthorization() } }
                Task { await model.syncCommutePush() }
            }
            Toggle(isOn: $settings.exitReminders) {
                IconLabel(title: String(localized: "Ans Aussteigen erinnern"), systemImage: "bell.badge.fill", color: .settingsIcon)
            }
            .tint(.brandText)
            .onChange(of: settings.exitReminders) { _, enabled in
                if enabled { Task { await ConnectionNotifier.requestAuthorization() } }
                model.scheduleExitReminderSync()
            }
            if settings.exitReminders {
                Picker(selection: $settings.exitReminderLead) {
                    ForEach(ExitReminderLead.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    IconLabel(title: String(localized: "Erinnerung"), systemImage: "clock.fill", color: .settingsIcon)
                }
                .onChange(of: settings.exitReminderLead) { model.scheduleExitReminderSync() }
            }
            if LiveActivityManager.isSupported {
                Toggle(isOn: $settings.liveActivitiesEnabled) {
                    IconLabel(title: String(localized: "Live-Aktivitäten"), systemImage: "bolt.badge.clock.fill", color: .settingsIcon)
                }
                .tint(.brandText)
                .onChange(of: settings.liveActivitiesEnabled) { model.syncLiveActivity() }
                if settings.liveActivitiesEnabled {
                    Toggle(isOn: $settings.liveActivityServerUpdates) {
                        IconLabel(title: String(localized: "Live-Aktivität über Server aktualisieren"), systemImage: "arrow.trianglehead.2.clockwise",
                                  color: .settingsIcon)
                    }
                    .tint(.brandText)
                    .onChange(of: settings.liveActivityServerUpdates) {
                        // Whether an activity gets updates from our server is fixed when it starts.
                        Task {
                            await model.liveActivities.restart()
                            model.syncLiveActivity()
                        }
                    }
                }
            }
        } header: {
            FormHeader("Meine Reisen")
        } footer: {
            Text(settings.liveActivitiesEnabled && LiveActivityManager.isSupported
                 ? "Wir sagen dir Bescheid bei Ausfällen, Gleiswechseln und verpassten Anschlüssen – und kurz bevor du aussteigen musst. Über unseren Server zeigt die Live-Aktivität auch bei geschlossener App aktuelle Zeiten und Gleise. Er bekommt dafür deine Reise bis zur Ankunft."
                 : "Wir sagen dir Bescheid bei Ausfällen, Gleiswechseln und verpassten Anschlüssen – und kurz bevor du aussteigen musst.")
        }
    }
}

/// Calendar events of saved journeys (#382).
struct CalendarSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Picker(selection: Binding(get: { settings.calendarAccess ?? .full },
                                      set: { settings.calendarAccess = $0 })) {
                ForEach(CalendarAccessMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                IconLabel(title: String(localized: "Zugriff"), systemImage: "calendar", color: .settingsIcon)
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
                IconLabel(title: String(localized: "Automatisch"), systemImage: "calendar.badge.clock", color: .settingsIcon)
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
            FormHeader("Kalender")
        } footer: {
            Text("Mit vollem Zugriff bleiben die Termine deiner Reisen aktuell und verschwinden mit der Reise. „Nur hinzufügen“ trägt jeden Termin einmal in deinen Standardkalender ein. „Automatisch“ trägt jede gespeicherte Reise ein, beim Speichern oder bei der Abfahrt.")
        }
    }
}
