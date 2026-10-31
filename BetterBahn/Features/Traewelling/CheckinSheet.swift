import BetterBahnKit
import SwiftUI

struct CheckinSheet: View {
    let leg: Leg

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design
    @State private var message = ""
    @State private var visibility: TraewellingVisibility = .publicVisible
    @State private var business: TraewellingBusiness = .privateTrip
    @State private var toot = false
    @State private var isLoggedIn = false
    @State private var isSending = false
    @State private var result: CheckinResult?
    @State private var error: Error?
    @State private var offerManualTrip = false
    /// Träwelling still has the user on another train at that time (`.collision`), e.g. because the
    /// previous one arrived early; offers to check in anyway. Remembers whether it was the manual trip.
    @State private var offerForcedCheckin = false
    @State private var forcedAsManualTrip = false
    @State private var activeTags: Set<String> = []
    @State private var tagValues: [String: String] = [:]
    /// For coupled trains (`Line.coupledTrains`): which of them the user sits in, picked by hand since
    /// Träwelling knows them as separate trains. Nil until picked.
    @State private var chosenTrain: String?
    @State private var emojis: [CustomEmoji] = []
    /// Whether the account collects Träwelling points; otherwise the "+0 Punkte" chip stays hidden.
    @State private var showsPoints = false
    @FocusState private var messageFocused: Bool
    @FocusState private var focusedTag: String?
    /// Where the keyboard was when "Jetzt einchecken" was tapped. It goes away right then, and only
    /// comes back there if Träwelling rejects the input (`isInvalidInput`), so it can be fixed.
    @State private var focusBeforeSend: (message: Bool, tag: String?) = (false, nil)

    private var coupledTrains: [Line.CoupledTrain] { leg.line?.coupledTrains ?? [] }

    /// The leg as checked in: as the picked train for coupled trains.
    private var rideLeg: Leg {
        guard let chosenTrain, let train = coupledTrains.first(where: { $0.name == chosenTrain }) else { return leg }
        return leg.riding(train)
    }

    private var needsTrainChoice: Bool { !coupledTrains.isEmpty && chosenTrain == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CheckinTicket(leg: rideLeg)

                    if !isLoggedIn {
                        loginCard
                    } else if let result {
                        successCard(result)
                    } else {
                        if !coupledTrains.isEmpty { trainChoiceCard }
                        formCard
                        if let error {
                            ErrorBanner(error: error)
                        }
                        sendButton
                    }
                }
                .padding()
            }
            .closesMenusOnScroll()
            .background { AppBackground() }
            .navigationTitle("Träwelling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: result == nil ? .cancellationAction : .confirmationAction) {
                    if result == nil {
                        Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                    } else {
                        Button("Fertig", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
            .task {
                isLoggedIn = await model.traewelling.isLoggedIn
                visibility = model.settings.traewellingVisibility
                await loadAccount()
            }
            .alert("Zug nicht gefunden", isPresented: $offerManualTrip) {
                Button("Manuell eintragen") { send(asManualTrip: true) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Träwelling kennt \(rideLeg.line?.name ?? String(localized: "diesen Zug")) nicht. Du kannst ihn selbst eintragen.")
            }
            .alert("Schon eingecheckt", isPresented: $offerForcedCheckin) {
                Button("Trotzdem einchecken") { send(asManualTrip: forcedAsManualTrip, force: true) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text(showsPoints
                     ? "Du bist bei Träwelling zu dieser Zeit schon in einem anderen Zug eingecheckt. Trotzdem einchecken? Dafür gibt es keine Punkte."
                     : "Du bist bei Träwelling zu dieser Zeit schon in einem anderen Zug eingecheckt. Trotzdem einchecken?")
            }
        }
    }

    private var loginCard: some View {
        Card {
            VStack(spacing: 12) {
                IconTile(systemImage: "person.badge.key.fill", color: .brand, size: 48)
                Text("Bei Träwelling anmelden")
                    .font(.headline)
                    .fontDesign(design == .fahrkarte ? .rounded : nil)
                Text("Zum Einchecken brauchst du ein Träwelling-Konto.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TraewellingLoginButton {
                    isLoggedIn = true
                    Task { await loadAccount() }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Asked each time a check-in opens, so a newly connected Mastodon account or a changed points
    /// setting counts at once.
    private func loadAccount() async {
        let user = await model.traewellingUser()
        showsPoints = user?.pointsEnabled == true
        emojis = await model.checkinEmojis(for: user)
    }

    private func successCard(_ result: CheckinResult) -> some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.punctual.gradient)
                    .symbolEffect(.bounce, value: result.points)
                Text("Eingecheckt")
                    .font(.title2.weight(.bold))
                    .fontDesign(design == .fahrkarte ? .rounded : nil)
                HStack(spacing: 8) {
                    if showsPoints {
                        InfoChip(text: String(localized: "+\(result.points) Punkte"), systemImage: "sparkles", tint: .brand)
                    }
                    if result.alsoOnThisConnection > 0 {
                        InfoChip(text: String(localized: "\(result.alsoOnThisConnection) Mitreisende"), systemImage: "person.2.fill", tint: .punctual)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    /// Coupled trains split later on, and Träwelling needs the one actually ridden.
    private var trainChoiceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconTile(systemImage: "arrow.triangle.branch", color: .orange, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In welchem Zugteil sitzt du?").font(.subheadline.weight(.medium))
                        Text("Die Züge fahren gekoppelt und trennen sich später.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(trainChoices, id: \.name) { train in
                    let isChosen = chosenTrain == train.name
                    Button {
                        withAnimation(.snappy) { chosenTrain = train.name }
                    } label: {
                        HStack {
                            Text(train.name).font(.subheadline.weight(.semibold))
                            if let direction = train.direction {
                                Text("→ \(direction)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isChosen ? Color.brand : .secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The leg's own train first, then the ones coupled to it.
    private var trainChoices: [Line.CoupledTrain] {
        guard let line = leg.line else { return [] }
        return [Line.CoupledTrain(name: line.name, direction: leg.direction)] + coupledTrains
    }

    private var formCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                EmojiMessageField(message: $message, emojis: emojis, isFocused: $messageFocused)
                Divider()
                MenuPickerRow(title: String(localized: "Sichtbarkeit"), icon: "eye.fill", color: .purple, selection: $visibility,
                              options: TraewellingVisibility.allCases) { $0.label }
                Divider()
                MenuPickerRow(title: String(localized: "Reiseart"), icon: "briefcase.fill", color: .orange, selection: $business,
                              options: TraewellingBusiness.allCases) { $0.label }
                if !model.settings.quickTags.isEmpty {
                    Divider()
                    tagsRow
                }
                Divider()
                Toggle(isOn: $toot) {
                    HStack(spacing: 12) {
                        IconTile(systemImage: "megaphone.fill", color: .indigo, size: 32)
                        Text("Auf Mastodon teilen").font(.subheadline.weight(.medium))
                    }
                }
                .tint(.brand)
            }
        }
    }

    private var tagsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(systemImage: "tag.fill", color: .brand, size: 32)
                Text("Tags").font(.subheadline.weight(.medium))
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.settings.quickTags) { tag in
                        tagChip(tag)
                    }
                }
            }
            ForEach(model.settings.quickTags.filter { $0.value == nil && activeTags.contains($0.id) }) { tag in
                TextField(tag.label, text: valueBinding(for: tag))
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .focused($focusedTag, equals: tag.id)
            }
        }
    }

    private func tagChip(_ tag: QuickTag) -> some View {
        let isOn = activeTags.contains(tag.id)
        return Button {
            withAnimation(.snappy) {
                if isOn { activeTags.remove(tag.id) } else { activeTags.insert(tag.id) }
            }
        } label: {
            Label(tag.label, systemImage: tag.systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color.brand : Color.primary.opacity(0.07), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func valueBinding(for tag: QuickTag) -> Binding<String> {
        Binding(get: { tagValues[tag.id] ?? "" }, set: { tagValues[tag.id] = $0 })
    }

    private var sendButton: some View {
        Button {
            focusBeforeSend = (messageFocused, focusedTag)
            messageFocused = false
            focusedTag = nil
            send()
        } label: {
            Group {
                if isSending {
                    ProgressView()
                } else {
                    Label("Jetzt einchecken", systemImage: "checkmark.seal.fill")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .pageButtonStyle(.prominent)
        .tint(.brand)
        .controlSize(.large)
        .disabled(isSending || message.count > 280 || needsTrainChoice)
    }

    private func send(asManualTrip: Bool = false, force: Bool = false) {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                if asManualTrip {
                    // The search for the train already failed before a manual trip is offered; don't run it again.
                    let leg = rideLeg
                    let checkin = try await model.traewelling.checkinAsManualTrip(draft(for: leg, force: force))
                    await finishSuccess(checkin, leg: leg)
                } else if let found = try await checkinFindingTrain(force: force) {
                    await finishSuccess(found.checkin, leg: found.leg)
                } else {
                    offerManualTrip = true
                }
            } catch OAuthError.notLoggedIn {
                isLoggedIn = false
            } catch TraewellingError.collision where !force {
                forcedAsManualTrip = asManualTrip
                offerForcedCheckin = true
            } catch {
                self.error = error
                if (error as? TraewellingError)?.isInvalidInput == true {
                    messageFocused = focusBeforeSend.message
                    focusedTag = focusBeforeSend.tag
                }
            }
        }
    }

    /// Checks in `rideLeg`, falling back to other ways Träwelling may know the train when its own
    /// timetable doesn't have it. `nil` if none works, so a manual trip is offered. The leg returned
    /// is the one actually checked in (another train name).
    private func checkinFindingTrain(force: Bool) async throws -> (checkin: CheckinResult, leg: Leg)? {
        do {
            return (try await attemptCheckin(leg: rideLeg, force: force), rideLeg)
        } catch TraewellingError.tripNotFound {}
        // Some international trains are listed under two names by separate feeds (e.g. an
        // ÖBB "RJ 177" that Deutsche Bahn's own live feed calls "ICE 177") — try the other
        // name Transitous knows about before asking to create a manual entry.
        if let alternate = await model.provider.alternateLineName(for: rideLeg), alternate != rideLeg.line?.name {
            var altLeg = rideLeg
            altLeg.line?.name = alternate
            if let checkin = try await fallback({ try await attemptCheckin(leg: altLeg, force: force) }) {
                return (checkin, altLeg)
            }
        }
        // `leg.origin` may be a Zusatzhalt (an unscheduled stop, e.g. after a diversion) —
        // Träwelling's own timetable never has those, which is exactly why the checkin above
        // just failed. Bridge the gap with a short manual trip instead of asking the user to
        // manually enter the whole rest of the journey.
        if let checkin = try await fallback({ try await attemptZusatzhaltCheckin(force: force) }) ?? nil {
            return (checkin, rideLeg)
        }
        return nil
    }

    /// A fallback attempt's result, `nil` if it failed. A collision still reaches the user, who can
    /// check in anyway; it would happen the same way with a manual trip.
    private func fallback<T>(_ attempt: () async throws -> T) async throws -> T? {
        do {
            return try await attempt()
        } catch TraewellingError.collision {
            throw TraewellingError.collision
        } catch {
            return nil
        }
    }

    private func attemptCheckin(leg: Leg, force: Bool) async throws -> CheckinResult {
        try await model.traewelling.checkin(draft(for: leg, force: force))
    }

    private func draft(for leg: Leg, force: Bool) -> CheckinDraft {
        CheckinDraft(leg: leg, message: message, visibility: visibility, business: business, toot: toot, force: force)
    }

    /// If `leg` boards at a Zusatzhalt bahn.de's journey details know about, checks in the hop up
    /// to the next regular stop as a short manual trip and then checks in normally from there. `nil`
    /// if bahn.de doesn't know this train, or `leg.origin` isn't actually a Zusatzhalt (some other
    /// reason Träwelling didn't recognise the departure).
    private func attemptZusatzhaltCheckin(force: Bool) async throws -> CheckinResult? {
        guard let bahnDe = model.provider.bahnDe,
              let stops = try await bahnDe.journeyStops(for: rideLeg),
              let (zusatzhalt, nextRegular) = BahnDeClient.nextRegularStop(after: rideLeg.origin, in: stops)
        else { return nil }
        return try await model.traewelling.checkin(draft(for: rideLeg, force: force), fromZusatzhalt: zusatzhalt, toNextRegularStop: nextRegular)
    }

    private func finishSuccess(_ checkin: CheckinResult, leg: Leg) async {
        withAnimation(.bouncy) { result = checkin }
        error = nil
        // Remembered for the leg as shown in the journey (not a picked coupled train), so its "Mehr" finds it.
        if let statusId = checkin.statusId { model.rememberCheckin(statusId: statusId, leg: self.leg) }
        if checkin.isManualTrip, let statusId = checkin.statusId {
            model.trackManualCheckin(statusId: statusId, leg: leg)
        }
        if let hop = checkin.zusatzhaltHop {
            model.trackManualCheckin(statusId: hop.statusId, leg: hop.leg)
        }
        // A train Träwelling splits into several trips (e.g. at a border) gets one status per part,
        // and tags like the seat apply to all of them.
        for statusId in [checkin.statusId].compactMap(\.self) + checkin.connectingStatusIds {
            await sendTags(statusId: statusId)
        }
    }

    /// Adds the tags the user picked to the freshly created status. Best-effort: the checkin
    /// itself already succeeded, so a single failed tag shouldn't surface as an error.
    private func sendTags(statusId: Int) async {
        for tag in model.settings.quickTags where activeTags.contains(tag.id) {
            let value = tag.value ?? tagValues[tag.id]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !value.isEmpty else { continue }
            _ = try? await model.traewelling.addTag(statusId: statusId, key: tag.key, value: value, visibility: visibility)
        }
    }
}

/// A form row with a leading icon/title and a trailing value that opens a `Menu` to pick from
/// `options` (check-in form and `CheckinDetailSheet`). Built on `Menu` rather than a system `Picker`
/// because a menu-style `Picker`'s auto-generated label ignores an outer `.lineLimit(1)` and can
/// still wrap a long selected value onto a second line; here the label is our own `Text`, so the
/// line limit actually takes effect and long values truncate with "…" instead.
///
/// The menu keeps the same width whatever is picked: if it shrank with its label ("Vertraute Nutzer"
/// → "Öffentlich"), iOS animates the closing menu back to the old frame and the new value sits in the
/// wrong place for about a second before snapping into place.
struct MenuPickerRow<T: Hashable>: View {
    let title: String
    let icon: String
    let color: Color
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: icon, color: color, size: 32)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                Text(label(selection))
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(.rect)
            }
            .frame(maxWidth: 150)
        }
    }
}

/// Summary of the leg at the top of the check-in sheets. Minimal: a card with the line, both stops and the
/// ride's duration. Fahrkarte: a ticket with the line above a perforation and labelled departure and arrival.
struct CheckinTicket: View {
    let leg: Leg
    @Environment(\.appDesign) private var design

    var body: some View {
        if design == .fahrkarte {
            ticket
        } else {
            card
        }
    }

    private var duration: String {
        leg.arrival.best.timeIntervalSince(leg.departure.best).compactDuration
    }

    // MARK: Minimal

    private var card: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    LineBadge(line: leg.line)
                    if let direction = leg.direction {
                        Text("Richtung \(direction)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                stops(label: false)
            }
        }
    }

    // MARK: Fahrkarte

    private var ticket: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                LineBadge(line: leg.line)
                Spacer(minLength: 8)
                if let direction = leg.direction {
                    Text("Richtung \(direction)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            TicketPerforation()
            stops(label: true)
                .padding(16)
        }
        .fontDesign(.rounded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ticketBackground()
        .environment(\.cardSurface, Color.ticket)
    }

    // MARK: Parts

    private func stops(label: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            stop(label: label ? String(localized: "Abfahrt") : nil, time: leg.departure, name: leg.origin.displayName,
                 platform: leg.departurePlatform, alignment: .leading)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Image(systemName: leg.line?.symbolName ?? "tram.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(duration)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, label ? 22 : 6)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            stop(label: label ? String(localized: "Ankunft") : nil, time: leg.arrival, name: leg.destination.displayName,
                 platform: leg.arrivalPlatform, alignment: .trailing)
        }
    }

    private func stop(label: String?, time: TimeInfo, name: String, platform: PlatformInfo?,
                      alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if let label {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            TimeStack(time: time, alignment: alignment, font: .title2.weight(.bold))
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            PlatformBadge(platform: platform)
        }
    }
}

#Preview("Check-in Ticket") {
    VStack {
        CheckinTicket(leg: PreviewData.firstLeg)
    }
    .padding()
    .frame(maxHeight: .infinity)
    .background { AppBackground() }
}
