import AuthenticationServices
import BetterBahnKit
import SwiftUI

/// Settings → Träwelling → Mitteilungen (#266, #447): pushes from our server about new check-ins of the
/// people the user follows, likes on the user's own check-ins and people checking in on the same train.
/// Each turns on alone; our server reads with the app's Träwelling login (#452). Likes and fellow travellers
/// with a login from before #452 sign in with Träwelling again first.
struct CheckinNotificationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    /// The kind waiting for the user to agree to signing in again.
    @State private var kindNeedingLogin: CheckinPushKind?
    /// The kind being turned on (`turningOn`) or off right now.
    @State private var changing: CheckinPushKind?
    @State private var turningOn = false
    @State private var error: Error?

    var body: some View {
        Form {
            Section {
                toggle(.followed, title: String(localized: "Check-ins von Gefolgten"), systemImage: "bell.badge.fill", color: .orange)
                toggle(.likes, title: String(localized: "Likes auf deine Check-ins"), systemImage: "heart.fill", color: .pink)
                toggle(.companions, title: String(localized: "Mitreisende"), systemImage: "person.2.fill", color: .teal,
                       subtitle: String(localized: "Wenn jemand in deinen Zug eincheckt."))
                if let error {
                    ErrorBanner(error: error)
                }
            } footer: {
                if !model.checkinPushKinds.isEmpty {
                    Text("Unser Server schaut alle 2 Minuten bei Träwelling nach. Dabei wird nichts gespeichert.")
                } else if model.followedCheckinPushEnded {
                    Text("Träwelling hat die Anmeldung für die Meldungen beendet. Zum Weitermachen wieder einschalten.")
                }
            }
        }
        .navigationTitle("Mitteilungen")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Dieses Feature benötigt eine erneute Anmeldung mit Träwelling. Möchtest du fortfahren?",
               isPresented: Binding { kindNeedingLogin != nil } set: { if !$0 { kindNeedingLogin = nil } },
               presenting: kindNeedingLogin) { kind in
            Button("Fortfahren") { change(kind, on: true) }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func toggle(_ kind: CheckinPushKind, title: String, systemImage: String, color: Color, subtitle: String? = nil) -> some View {
        Toggle(isOn: Binding {
            model.isCheckinPushOn(kind) || (changing == kind && turningOn)
        } set: { on in
            error = nil
            Task {
                if on, await model.checkinPushNeedsLogin(for: kind) {
                    kindNeedingLogin = kind
                } else {
                    change(kind, on: on)
                }
            }
        }) {
            HStack {
                IconLabel(title: title, systemImage: systemImage, color: color, subtitle: subtitle)
                if changing == kind {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .tint(.brand)
        .disabled(changing != nil)
    }

    /// Cancelling the Träwelling login leaves the setting off.
    private func change(_ kind: CheckinPushKind, on: Bool) {
        changing = kind
        turningOn = on
        Task {
            defer { changing = nil }
            do {
                try await model.setCheckinPush(kind, on: on) { url, scheme in
                    try await webAuthenticationSession.authenticate(using: url, callback: .customScheme(scheme),
                                                                    preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
                }
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            } catch {
                self.error = error
            }
        }
    }
}
