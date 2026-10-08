import BetterBahnKit
import SwiftUI

extension AppModel {
    /// Removes a saved journey, or – when it was checked in on Träwelling from this app – hands it to
    /// `checkoutPrompt` to ask first whether to check out.
    func remove(_ journey: Journey, askingToCheckOut prompt: inout Journey?) {
        if settings.traewellingEnabled, !checkins(in: journey).isEmpty {
            prompt = journey
        } else {
            withAnimation(.snappy) { unsave(journey) }
        }
    }
}

extension View {
    /// Asks whether to check out of the journey's Träwelling check-ins before removing it: end the ride
    /// under way at the last stop reached, delete the check-ins, or keep them.
    func checkoutPrompt(_ journey: Binding<Journey?>) -> some View {
        modifier(CheckoutPrompt(journey: journey))
    }
}

private struct CheckoutPrompt: ViewModifier {
    @Binding var journey: Journey?

    @Environment(AppModel.self) private var model
    @State private var failure: Failure?

    private struct Failure {
        let journey: Journey
        let error: Error
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Bei Träwelling auschecken?", isPresented: isAsking,
                                titleVisibility: .visible, presenting: journey) { journey in
                if let early = model.earlyCheckout(in: journey) {
                    Button("In \(early.exit.station.displayName) auschecken") { checkOut(journey, early: true) }
                }
                Button(model.checkins(in: journey).count > 1 ? "Check-ins löschen" : "Check-in löschen", role: .destructive) {
                    checkOut(journey, early: false)
                }
                Button("Eingecheckt bleiben") { remove(journey) }
                Button("Abbrechen", role: .cancel) {}
            } message: { journey in
                Text(message(for: journey))
            }
            .alert("Auschecken fehlgeschlagen", isPresented: hasFailed, presenting: failure) { failure in
                Button("Trotzdem entfernen", role: .destructive) { remove(failure.journey) }
                Button("Abbrechen", role: .cancel) {}
            } message: { failure in
                Text(failure.error.localizedDescription)
            }
    }

    private func message(for journey: Journey) -> String {
        if let early = model.earlyCheckout(in: journey) {
            let line = early.leg.line?.name ?? "dieser Fahrt"
            return "Du bist in \(line) eingecheckt. „In \(early.exit.station.displayName) auschecken“ beendet die Fahrt "
                + "dort und löscht spätere Check-ins dieser Reise."
        }
        return "Du bist auf dieser Reise bei Träwelling eingecheckt."
    }

    private var isAsking: Binding<Bool> {
        Binding(get: { journey != nil }, set: { if !$0 { journey = nil } })
    }

    private var hasFailed: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private func checkOut(_ journey: Journey, early: Bool) {
        Task {
            do {
                if early {
                    try await model.checkOutEarly(of: journey)
                } else {
                    try await model.deleteCheckins(in: journey)
                }
                remove(journey)
            } catch {
                failure = Failure(journey: journey, error: error)
            }
        }
    }

    private func remove(_ journey: Journey) {
        withAnimation(.snappy) { model.unsave(journey) }
    }
}
