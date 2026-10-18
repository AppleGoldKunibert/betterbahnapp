import BetterBahnKit
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
