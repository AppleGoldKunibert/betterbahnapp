import BetterBahnKit
import SwiftUI

/// The quick setup (#547): the settings most people want to choose once, one topic per page (Kit
/// `QuickSetupStep`). Opens from the top of Settings and, once, on the first start (`QuickSetup.opensOnLaunch`).
/// Every choice applies at once, so closing early keeps what was picked.
struct QuickSetupView: View {
    /// The first start opens with a welcome page; from Settings it starts with the first step.
    let welcome: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [QuickSetupStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if welcome {
                    QuickSetupWelcome(start: { path.append(.ticket) }, later: { dismiss() })
                } else {
                    page(.ticket)
                }
            }
            .navigationDestination(for: QuickSetupStep.self, destination: page)
        }
        .onAppear { model.settings.quickSetupSeen = true }
        // iOS asks before every icon change: change it once, when the setup is done.
        .onDisappear { Theme.shared.applyAppIcon() }
    }

    private func page(_ step: QuickSetupStep) -> some View {
        QuickSetupStepPage(step: step) {
            if step == .notifications, notificationsOn {
                // Switched on by default, so the switches alone never asked.
                Task { await ConnectionNotifier.requestAuthorization() }
            }
            if let next = step.next {
                path.append(next)
            } else {
                dismiss()
            }
        } close: {
            dismiss()
        }
    }

    private var notificationsOn: Bool {
        let settings = model.settings
        return settings.connectionWarnings || settings.exitReminders
    }
}

/// The first start's page: what the setup is, and to start it or leave it for later.
private struct QuickSetupWelcome: View {
    let start: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            AppLogoView(size: 96)
            Text("Willkommen bei BetterBahn")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Richte die App in \(QuickSetupStep.count) kurzen Schritten ein. Alles kannst du später in den Einstellungen ändern.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: 12) {
                Button(action: start) {
                    Text("Los geht’s")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .pageButtonStyle(.prominent)
                .controlSize(.large)
                Button("Später", action: later)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.brandText)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background { AppBackground() }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// One step: what it is about, the same settings as in the menus, and on to the next.
private struct QuickSetupStepPage: View {
    let step: QuickSetupStep
    let advance: () -> Void
    let close: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: step.symbolName)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Color.brandText)
                        .frame(height: 48)
                    Text(step.title)
                        .font(.title2.weight(.bold))
                    Text(step.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                .accessibilityElement(children: .combine)
            }
            content
        }
        .designedForm()
        .closesMenusOnScroll()
        .navigationTitle(Text("Schritt \(step.number) von \(QuickSetupStep.count)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Schließen", systemImage: "xmark", action: close)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if step.next == nil {
                    Text("Alles Weitere findest du in den Einstellungen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                advanceButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private var advanceButton: some View {
        Button(action: advance) {
            Text(step.next == nil ? "Fertig" : "Weiter")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .pageButtonStyle(.prominent)
        .controlSize(.large)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .ticket:
            TicketSettingsSection(showsLinks: false)
        case .travel:
            BikeSettingsSection()
            StepFreeSettingsSection()
        case .notifications:
            NotificationSettingsSection()
        case .calendar:
            CalendarSettingsSection()
        case .design:
            DesignChoiceSection()
            AccentChoiceSection()
        }
    }
}

extension QuickSetupStep {
    var title: String {
        switch self {
        case .ticket: String(localized: "Dein Ticket")
        case .travel: String(localized: "Unterwegs")
        case .notifications: String(localized: "Mitteilungen")
        case .calendar: String(localized: "Kalender")
        case .design: String(localized: "Design")
        }
    }

    var message: String {
        switch self {
        case .ticket: String(localized: "Mit welchem Ticket fährst du? Die Suche kann dann nur Züge zeigen, in denen es gilt.")
        case .travel: String(localized: "Nimmst du ein Fahrrad mit oder brauchst du einen Aufzug?")
        case .notifications: String(localized: "Wir sagen dir Bescheid, wenn auf deiner Reise etwas nicht klappt.")
        case .calendar: String(localized: "Trag deine Reisen in den Kalender ein, auf Wunsch automatisch.")
        case .design: String(localized: "Such dir aus, wie die App aussieht.")
        }
    }

    var symbolName: String {
        switch self {
        case .ticket: "ticket.fill"
        case .travel: "figure.walk"
        case .notifications: "bell.badge.fill"
        case .calendar: "calendar"
        case .design: "paintpalette.fill"
        }
    }
}
