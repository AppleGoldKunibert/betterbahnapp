import BetterBahnKit
import SwiftUI

struct CheckinSheet: View {
    let leg: Leg

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var visibility: TraewellingVisibility = .publicVisible
    @State private var business: TraewellingBusiness = .privateTrip
    @State private var toot = false
    @State private var isLoggedIn = false
    @State private var isSending = false
    @State private var result: CheckinResult?
    @State private var error: Error?
    @State private var offerManualTrip = false
    @State private var activeTags: Set<String> = []
    @State private var tagValues: [String: String] = [:]
    /// For coupled trains (`Line.coupledTrains`): which of them the user sits in, picked by hand since
    /// Träwelling knows them as separate trains. Nil until picked.
    @State private var chosenTrain: String?

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
            }
            .alert("Zug nicht gefunden", isPresented: $offerManualTrip) {
                Button("Manuell eintragen") { send(allowManualTrip: true) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Träwelling kennt \(rideLeg.line?.name ?? "diesen Zug") nicht. Du kannst ihn selbst eintragen.")
            }
        }
    }

    private var loginCard: some View {
        Card {
            VStack(spacing: 14) {
                IconTile(systemImage: "person.badge.key.fill", color: .brand, size: 52)
                Text("Bei Träwelling anmelden").font(.headline)
                Text("Zum Einchecken brauchst du ein Träwelling-Konto.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TraewellingLoginButton { isLoggedIn = true }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func successCard(_ result: CheckinResult) -> some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.punctual.gradient)
                    .symbolEffect(.bounce, value: result.points)
                Text("Eingecheckt").font(.title2.weight(.bold))
                HStack(spacing: 8) {
                    InfoChip(text: "+\(result.points) Punkte", systemImage: "sparkles", tint: .brand)
                    if result.alsoOnThisConnection > 0 {
                        InfoChip(text: "\(result.alsoOnThisConnection) Mitreisende", systemImage: "person.2.fill", tint: .punctual)
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
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "text.bubble.fill", color: .blue, size: 32)
                    TextField("Was geht ab? (optional)", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(.top, 5)
                }
                if !message.isEmpty {
                    Text("\(message.count)/280")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(message.count > 280 ? Color.heavyDelay : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider()
                pickerRow("Sichtbarkeit", icon: "eye.fill", color: .purple, selection: $visibility, options: TraewellingVisibility.allCases) { $0.label }
                Divider()
                pickerRow("Reiseart", icon: "briefcase.fill", color: .orange, selection: $business, options: TraewellingBusiness.allCases) { $0.label }
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

    /// A settings row with a leading icon/title and a trailing value that opens a `Menu` to pick
    /// from `options`. Built on `Menu` rather than a system `Picker` because a menu-style
    /// `Picker`'s auto-generated label ignores an outer `.lineLimit(1)` and can still wrap a long
    /// selected value onto a second line; here the label is our own `Text`, so the line limit
    /// actually takes effect and long values truncate with "…" instead.
    private func pickerRow<T: Hashable>(_ title: String, icon: String, color: Color,
                                        selection: Binding<T>, options: [T], label: @escaping (T) -> String) -> some View {
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
                        selection.wrappedValue = option
                    } label: {
                        if option == selection.wrappedValue {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                Text(label(selection.wrappedValue))
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 150, alignment: .trailing)
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
                .foregroundStyle(isOn ? .white : Color.brand)
                .background(isOn ? Color.brand : Color.brand.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func valueBinding(for tag: QuickTag) -> Binding<String> {
        Binding(get: { tagValues[tag.id] ?? "" }, set: { tagValues[tag.id] = $0 })
    }

    private var sendButton: some View {
        Button(action: { send() }) {
            Group {
                if isSending {
                    ProgressView()
                } else {
                    Label("Jetzt einchecken", systemImage: "checkmark.seal.fill")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.brand)
        .controlSize(.large)
        .disabled(isSending || message.count > 280 || needsTrainChoice)
    }

    private func send(allowManualTrip: Bool = false) {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let leg = rideLeg
                let checkin = try await attemptCheckin(leg: leg, allowManualTrip: allowManualTrip)
                await finishSuccess(checkin, leg: leg)
            } catch OAuthError.notLoggedIn {
                isLoggedIn = false
            } catch TraewellingError.tripNotFound where !allowManualTrip {
                // Some international trains are listed under two names by separate feeds (e.g. an
                // ÖBB "RJ 177" that Deutsche Bahn's own live feed calls "ICE 177") — try the other
                // name Transitous knows about before asking to create a manual entry.
                if let alternate = await model.provider.alternateLineName(for: rideLeg) {
                    var altLeg = rideLeg
                    altLeg.line?.name = alternate
                    if let checkin = try? await attemptCheckin(leg: altLeg, allowManualTrip: false) {
                        await finishSuccess(checkin, leg: altLeg)
                        return
                    }
                }
                // `leg.origin` may be a Zusatzhalt (an unscheduled stop, e.g. after a diversion) —
                // Träwelling's own timetable never has those, which is exactly why the checkin above
                // just failed. Bridge the gap with a short manual trip instead of asking the user to
                // manually enter the whole rest of the journey.
                if let checkin = try? await attemptZusatzhaltCheckin() {
                    await finishSuccess(checkin, leg: rideLeg)
                    return
                }
                offerManualTrip = true
            } catch {
                self.error = error
            }
        }
    }

    private func attemptCheckin(leg: Leg, allowManualTrip: Bool) async throws -> CheckinResult {
        let draft = CheckinDraft(leg: leg, message: message, visibility: visibility, business: business, toot: toot)
        return try await model.traewelling.checkin(draft, allowManualTrip: allowManualTrip)
    }

    /// If `leg` boards at a Zusatzhalt bahn.de's journey details know about, checks in the hop up
    /// to the next regular stop as a short manual trip and then checks in normally from there. `nil`
    /// if bahn.de doesn't know this train, or `leg.origin` isn't actually a Zusatzhalt (some other
    /// reason Träwelling didn't recognise the departure).
    private func attemptZusatzhaltCheckin() async throws -> CheckinResult? {
        guard let bahnDe = model.provider.bahnDe,
              let stops = try await bahnDe.journeyStops(for: rideLeg),
              let (zusatzhalt, nextRegular) = BahnDeClient.nextRegularStop(after: rideLeg.origin, in: stops)
        else { return nil }
        let draft = CheckinDraft(leg: rideLeg, message: message, visibility: visibility, business: business, toot: toot)
        return try await model.traewelling.checkin(draft, fromZusatzhalt: zusatzhalt, toNextRegularStop: nextRegular)
    }

    private func finishSuccess(_ checkin: CheckinResult, leg: Leg) async {
        withAnimation(.bouncy) { result = checkin }
        error = nil
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

/// Ticket-style summary of the leg.
struct CheckinTicket: View {
    let leg: Leg

    var body: some View {
        let color = leg.line?.product.color ?? .brand
        VStack(spacing: 0) {
            HStack {
                LineBadge(line: leg.line)
                Spacer()
                if let direction = leg.direction {
                    Text("Richtung \(direction)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(14)
            .background(color.gradient)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    TimeStack(time: leg.departure, font: .title2.weight(.bold))
                    Text(leg.origin.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                    PlatformBadge(platform: leg.departurePlatform)
                }
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: leg.line?.product.symbolName ?? "tram.fill")
                        .font(.title3)
                        .foregroundStyle(color)
                    Text(leg.arrival.best.timeIntervalSince(leg.departure.best).compactDuration)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    TimeStack(time: leg.arrival, alignment: .trailing, font: .title2.weight(.bold))
                    Text(leg.destination.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    PlatformBadge(platform: leg.arrivalPlatform)
                }
            }
            .padding(16)
        }
        .background(Color.card)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
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
