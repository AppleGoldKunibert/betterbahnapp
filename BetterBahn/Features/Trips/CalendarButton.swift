import BetterBahnKit
import EventKit
import SwiftUI
import UIKit

/// "Zum Kalender hinzufügen" for a saved journey (#382). The first time it asks whether the event may
/// be kept current (full calendar access) or only added once.
struct CalendarButton: View {
    @Environment(AppModel.self) private var model
    let entry: SavedJourney

    @State private var asksForAccess = false
    @State private var showsNoAccess = false
    @State private var isAdding = false

    private var isInCalendar: Bool { model.isInCalendar(entry) }

    var body: some View {
        Button {
            if model.settings.calendarAccess == nil { asksForAccess = true } else { add() }
        } label: {
            Image(systemName: isInCalendar ? "calendar.badge.checkmark" : "calendar.badge.plus")
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .tint(.brand)
        .disabled(isInCalendar || isAdding)
        .accessibilityLabel(isInCalendar ? "Im Kalender" : "Zum Kalender hinzufügen")
        .confirmationDialog("Zum Kalender hinzufügen", isPresented: $asksForAccess, titleVisibility: .visible) {
            Button("Voller Zugriff (empfohlen)") { choose(.full) }
            Button("Nur hinzufügen") { choose(.addOnly) }
        } message: {
            Text("Mit vollem Zugriff bleibt der Termin aktuell, auch bei Verspätungen, Gleiswechseln und wenn du die Reise löschst. Sonst wird er nur einmal eingetragen. Du kannst das in den Einstellungen ändern.")
        }
        .alert("Kein Zugriff auf den Kalender", isPresented: $showsNoAccess) {
            Button("Einstellungen") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Erlaube BetterBahn in den Einstellungen den Zugriff auf deinen Kalender.")
        }
    }

    private func choose(_ mode: CalendarAccessMode) {
        model.settings.calendarAccess = mode
        add()
    }

    private func add() {
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                try await model.addToCalendar(entry)
            } catch AppModel.CalendarError.noAccess {
                showsNoAccess = true
            } catch {}
        }
    }
}

/// Settings row choosing the calendar new journey events go to. Lists the calendars only with full access:
/// without it iOS doesn't show them. Events already added stay where they are.
struct CalendarChoiceRow: View {
    @Environment(AppModel.self) private var model
    @State private var calendars: [EKCalendar] = []

    var body: some View {
        @Bindable var settings = model.settings
        Picker(selection: $settings.calendarID) {
            Text("Standardkalender").tag(String?.none)
            ForEach(calendars, id: \.calendarIdentifier) { calendar in
                Label {
                    Text(calendar.title)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: calendar.cgColor))
                }
                .tag(Optional(calendar.calendarIdentifier))
            }
        } label: {
            IconLabel(title: "Kalender für neue Termine", systemImage: "calendar.badge.plus", color: .red)
        }
        .task(id: model.calendarAccessChanges) {
            calendars = model.writableCalendars()
            // A calendar deleted since then: new events go to the default one again.
            if let id = model.settings.calendarID, !calendars.isEmpty,
               !calendars.contains(where: { $0.calendarIdentifier == id }) {
                model.settings.calendarID = nil
            }
        }
    }
}
