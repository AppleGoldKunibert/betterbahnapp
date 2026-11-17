import BetterBahnKit
import SwiftUI

/// Checks in on every train of a journey at once (#574): one form for all of them, then one check-in after the
/// other, each train's row telling how it went. A train Träwelling doesn't know or another check-in at that time
/// gets its own button, like in `CheckinSheet`.
struct GroupCheckinSheet: View {
    let legs: [Leg]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design
    @State private var group: GroupCheckin
    @State private var message = ""
    @State private var visibility: TraewellingVisibility = .publicVisible
    @State private var business: TraewellingBusiness = .privateTrip
    @State private var toot = false
    @State private var activeTags: Set<String> = []
    @State private var tagValues: [String: String] = [:]
    /// For coupled trains (`Line.coupledTrains`): the train the user sits in, per leg.
    @State private var chosenTrains: [String: String] = [:]
    @State private var isLoggedIn = true
    @State private var emojis: [CustomEmoji] = []
    @State private var showsPoints = false
    @FocusState private var messageFocused: Bool
    @FocusState private var focusedTag: String?

    /// - Parameter checkedIn: IDs of the legs already checked in: shown as done and skipped.
    init(legs: [Leg], checkedIn: Set<String>) {
        self.legs = legs
        _group = State(initialValue: GroupCheckin(legs: legs, checkedIn: checkedIn))
    }

    /// The form stays until the first train is checked in; after that, retrying uses what was sent.
    private var showsForm: Bool { group.checkedInCount == 0 && !group.isSending }

    private var needsTrainChoice: Bool {
        legs.contains { $0.needsCoupledTrainChoice && group.toSend.contains($0.id) && chosenTrains[$0.id] == nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    trainsCard
                    if !isLoggedIn {
                        TraewellingLoginCard {
                            isLoggedIn = true
                            Task { await loadAccount() }
                        }
                    } else if group.isDone {
                        successCard
                    } else {
                        if showsForm {
                            ForEach(legs.filter { $0.needsCoupledTrainChoice && group.toSend.contains($0.id) }) { leg in
                                CoupledTrainChoice(leg: leg, chosenTrain: chosenTrain(for: leg), showsLine: true)
                            }
                            CheckinFormCard(message: $message, visibility: $visibility, business: $business, toot: $toot,
                                            activeTags: $activeTags, tagValues: $tagValues, emojis: emojis,
                                            messageFocused: $messageFocused, focusedTag: $focusedTag)
                        }
                        if !group.toSend.isEmpty || group.isSending {
                            sendButton
                        }
                    }
                }
                .padding()
            }
            .closesMenusOnScroll()
            .background { AppBackground() }
            .navigationTitle("Alle Züge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: group.hasStarted ? .confirmationAction : .cancellationAction) {
                    if group.hasStarted {
                        Button("Fertig", systemImage: "checkmark") { dismiss() }
                            .disabled(group.isSending)
                    } else {
                        Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(group.isSending)
            .task {
                isLoggedIn = await model.traewelling.isLoggedIn
                visibility = model.settings.traewellingVisibility
                await loadAccount()
            }
        }
    }

    private func loadAccount() async {
        let user = await model.traewellingUser()
        showsPoints = user?.pointsEnabled == true
        emojis = await model.checkinEmojis(for: user)
    }

    private func chosenTrain(for leg: Leg) -> Binding<String?> {
        Binding(get: { chosenTrains[leg.id] }, set: { chosenTrains[leg.id] = $0 })
    }

    // MARK: Trains

    private var trainsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                    if index > 0 { Divider() }
                    trainRow(leg)
                }
            }
        }
    }

    private func trainRow(_ leg: Leg) -> some View {
        let state = group.state(of: leg.id)
        let ridden = leg.riding(trainNamed: chosenTrains[leg.id])
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LineBadge(line: ridden.line)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(leg.origin.displayName) → \(leg.destination.displayName)")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(leg.departure.best, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                stateIcon(state)
            }
            if let note = note(for: state) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch state {
            case .trainNotFound:
                Button("Manuell eintragen") { Task { await send(leg, asManualTrip: true) } }
                    .font(.subheadline.weight(.medium))
                    .disabled(group.isSending)
            case .collision:
                Button("Trotzdem einchecken") { Task { await send(leg, force: true) } }
                    .font(.subheadline.weight(.medium))
                    .disabled(group.isSending)
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func stateIcon(_ state: GroupCheckin.State) -> some View {
        switch state {
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .sending:
            ProgressView()
        case .checkedIn, .alreadyCheckedIn:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.punctual)
                .accessibilityLabel("Eingecheckt")
        case .trainNotFound, .collision:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func note(for state: GroupCheckin.State) -> String? {
        switch state {
        case .alreadyCheckedIn:
            String(localized: "Schon eingecheckt")
        case .checkedIn(let points, _) where showsPoints:
            String(localized: "+\(points) Punkte")
        case .trainNotFound:
            String(localized: "Träwelling kennt diesen Zug nicht. Du kannst ihn selbst eintragen.")
        case .collision:
            showsPoints
                ? String(localized: "Du bist zu dieser Zeit schon in einem anderen Zug eingecheckt. Dafür gibt es keine Punkte.")
                : String(localized: "Du bist zu dieser Zeit schon in einem anderen Zug eingecheckt.")
        case .failed(let message):
            message
        default:
            nil
        }
    }

    // MARK: Sending

    private var sendButton: some View {
        Button {
            messageFocused = false
            focusedTag = nil
            Task { await sendAll() }
        } label: {
            Group {
                if group.isSending {
                    ProgressView()
                } else if group.hasStarted {
                    Label("Erneut versuchen", systemImage: "arrow.clockwise")
                } else {
                    Label("Alle einchecken", systemImage: "checkmark.seal.fill")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .pageButtonStyle(.prominent)
        .tint(.brand)
        .controlSize(.large)
        .disabled(group.isSending || message.count > 280 || needsTrainChoice)
    }

    /// One train after the other, in the journey's order; stops when the login is gone.
    private func sendAll() async {
        for id in group.toSend {
            guard let leg = legs.first(where: { $0.id == id }) else { continue }
            guard await send(leg) else { return }
        }
    }

    /// Checks in on `leg` and keeps how it went. `false` when the user has to log in first.
    @discardableResult
    private func send(_ leg: Leg, asManualTrip: Bool = false, force: Bool = false) async -> Bool {
        group.set(.sending, for: leg.id)
        let draft = CheckinDraft(leg: leg.riding(trainNamed: chosenTrains[leg.id]), message: message, visibility: visibility,
                                 business: business, toot: toot, force: force)
        let tags = model.checkinTags(active: activeTags, values: tagValues, visibility: visibility)
        do {
            let made: AppModel.MadeCheckin?
            if asManualTrip {
                // The search for the train already failed before a manual trip is offered; don't run it again.
                made = try await model.checkinAsManualTrip(draft, shownLeg: leg, tags: tags)
            } else {
                made = try await model.checkin(draft, shownLeg: leg, tags: tags)
            }
            withAnimation(.snappy) {
                if let made {
                    group.set(.checkedIn(points: made.result.points, companions: made.result.alsoOnThisConnection), for: leg.id)
                } else {
                    group.set(.trainNotFound, for: leg.id)
                }
            }
        } catch OAuthError.notLoggedIn {
            group.set(.waiting, for: leg.id)
            isLoggedIn = false
            return false
        } catch TraewellingError.collision where !force {
            withAnimation(.snappy) { group.set(.collision, for: leg.id) }
        } catch {
            withAnimation(.snappy) { group.set(.failed(error.localizedDescription), for: leg.id) }
        }
        return true
    }

    private var successCard: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.punctual.gradient)
                    .symbolEffect(.bounce, value: group.checkedInCount)
                Text("In alle Züge eingecheckt")
                    .font(.title2.weight(.bold))
                    .fontDesign(design == .fahrkarte ? .rounded : nil)
                    .multilineTextAlignment(.center)
                if showsPoints, group.points > 0 {
                    InfoChip(text: String(localized: "+\(group.points) Punkte"), systemImage: "sparkles", tint: .brandText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}
