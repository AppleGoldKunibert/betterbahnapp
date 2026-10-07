import BetterBahnKit
import SwiftUI
import UIKit

struct JourneyDetailView: View {
    @State var journey: Journey
    let finalDestination: Station
    /// Old plans are shown without actions.
    var readOnly = false
    var title = "Reiseplan"
    /// Options this journey was searched with, so a re-plan can pick them up.
    var search: ConnectionSearch?

    @Environment(AppModel.self) private var model
    @State private var legToReplace: LegSelection?
    @State private var legToReplan: LegSelection?
    @State private var checkinLeg: Leg?
    @State private var showAlternatives = false
    @State private var showJourneyMap = false
    @State private var showJourneyEditor = false
    /// Set once the live data asked for on opening is in (or took longer than `LoadingDeadline.liveData`),
    /// so a journey never loaded live before doesn't first show the timetable and then jump to the delays.
    /// One seen before shows its last live data at once and refreshes in the background.
    @State private var liveDataLoaded = false
    /// The destination picked when the journey was edited, so later edits and "Anderer Zug" route there
    /// instead of back to the one the journey was opened with.
    @State private var editedDestination: Station?

    /// Where the journey is going now.
    private var goal: Station { editedDestination ?? finalDestination }

    struct LegSelection: Identifiable {
        let index: Int
        let leg: Leg
        var id: String { leg.id }
    }

    var body: some View {
        ScrollView {
            if !liveDataLoaded, loadsLiveDataOnOpen {
                ProgressView("Lade Echtzeitdaten …")
                    .containerRelativeFrame([.horizontal, .vertical])
            } else {
                plan
            }
        }
        .refreshable {
            await TimetablesClient.invalidateDelays()
            await refreshRealtime()
        }
        .task {
            if !readOnly, model.savedEntry(for: journey) == nil, let seen = model.liveJourneys.value(for: journey.id) {
                journey = seen
            }
            await LoadingDeadline.run({ @MainActor in
                await refreshRecentlyFinished()
                await fillMissingPlatforms()
                // Live data right away on opening, instead of only after the first pull-to-refresh.
                await refreshRealtime()
            }, showingAfter: LoadingDeadline.liveData) { liveDataLoaded = true }
            liveDataLoaded = true
            // Keep a saved journey's delays current while it's open.
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.realtimeRefreshInterval)
                guard !Task.isCancelled else { return }
                if model.savedEntry(for: journey) != nil { await refreshRealtime() }
            }
        }
        .tabBarSafePadding()
        .background { AppBackground() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $legToReplace) { selection in
            AlternativeTrainsSheet(leg: selection.leg) { newLegs in
                let updated = try await model.trainPicker.replacing(
                    legAt: selection.index, in: journey, with: newLegs, finalDestination: goal)
                withAnimation {
                    if let entry = model.savedEntry(for: journey) {
                        model.replaceSaved(id: entry.id, with: updated, reason: "Anderer Zug gewählt")
                    }
                    journey = updated
                }
            }
        }
        .sheet(item: $legToReplan) { selection in
            JourneyReplanSheet(journey: journey, startLeg: selection.leg, finalDestination: goal,
                               search: replanSearch) { updated, destination in
                editedDestination = destination
                withAnimation { journey = updated }
            }
        }
        .sheet(isPresented: $showJourneyEditor) {
            JourneyReplanSheet(journey: journey, finalDestination: goal,
                               search: replanSearch) { updated, destination in
                editedDestination = destination
                withAnimation { journey = updated }
            }
        }
        .sheet(item: $checkinLeg) { CheckinSheet(leg: $0) }
        .sheet(isPresented: $showAlternatives) {
            if let entry = model.savedEntry(for: journey) {
                AlternativeJourneySheet(entry: entry) { newJourney in
                    withAnimation { journey = newJourney }
                }
            }
        }
        .sheet(isPresented: $showJourneyMap) {
            JourneyMapView(journey: journey, finalDestination: goal)
        }
        .onChange(of: model.savedEntry(for: journey)?.journey) { _, refreshed in
            // Pick up realtime refreshes of this saved journey.
            if let refreshed, refreshed != journey { journey = refreshed }
        }
    }

    private var plan: some View {
        VStack(spacing: 16) {
            summaryCard
            if !readOnly { issuesCard }
            ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                if !leg.isWalking {
                    LegCard(
                        leg: leg,
                        transferBroken: !journey.isOver()
                            && journey.brokenTransferIndices.contains(journey.transitLegs.firstIndex(of: leg) ?? -1),
                        onReplace: readOnly || !model.settings.trainChoiceEnabled ? nil
                            : { legToReplace = LegSelection(index: index, leg: leg) },
                        onReplan: readOnly || !model.settings.editJourneyEnabled ? nil
                            : { legToReplan = LegSelection(index: index, leg: leg) },
                        onCheckin: readOnly || !model.settings.traewellingEnabled ? nil : { checkinLeg = leg },
                        reservation: model.reservation(for: leg, in: journey)
                    )
                    if let info = transferInfo(after: leg) {
                        TransferRow(from: leg, to: info.next, walk: info.walk, isPast: journey.isOver())
                    }
                }
            }
            if !readOnly { historySection }
        }
        .padding(.horizontal)
        .padding(.bottom, 32)
    }

    /// Whether opening waits for live data (see the `.task` above): only for a journey not seen live yet.
    private var loadsLiveDataOnOpen: Bool { !readOnly && !model.hasLiveData(for: journey) }

    /// The options to start a re-plan from: this view's own, else whatever was saved with the journey.
    private var replanSearch: ConnectionSearch? { search ?? model.savedEntry(for: journey)?.search }

    /// Pull-to-refresh: re-fetches realtime data (delays, platforms, cancellations) for every leg.
    private func refreshRealtime() async {
        guard !readOnly else { return }
        let refreshed = await model.journeyRefresher.refresh(journey)
        if model.savedEntry(for: journey) == nil { model.rememberLive(refreshed) }
        guard refreshed != journey else { return }
        if let entry = model.savedEntry(for: journey) {
            model.updateSavedJourneyData(id: entry.id, journey: refreshed)
        }
        withAnimation { journey = refreshed }
    }

    /// A saved journey is only refreshed until 10 minutes after it arrives, so its end keeps whatever
    /// delay DB reported last, often before the train got there. Opened within 24 hours of arriving,
    /// it's refreshed once more and stored, so it shows the real arrival like the trip view does.
    /// Once neither source has live data any more, the refresh keeps the delays it already had.
    private func refreshRecentlyFinished() async {
        guard let entry = recentlyFinishedEntry else { return }
        let refreshed = await model.journeyRefresher.refresh(journey)
        guard refreshed != journey else { return }
        model.updateSavedJourneyData(id: entry.id, journey: refreshed)
        withAnimation { journey = refreshed }
    }

    private var recentlyFinishedEntry: SavedJourney? {
        guard readOnly, let entry = model.pastJourneys.first(where: { $0.journey == journey }),
              let arrival = journey.arrival?.planned, arrival.addingTimeInterval(SavedJourney.liveDataLifetime) > .now else { return nil }
        return entry
    }

    /// Saved or imported journeys may still lack a Gleis Transitous didn't have; DB's schedule fills it.
    private func fillMissingPlatforms() async {
        guard !readOnly, let timetables = model.timetablesClient else { return }
        let filled = await timetables.fillMissingPlatforms(in: journey)
        guard filled != journey else { return }
        if let entry = model.savedEntry(for: journey) {
            model.updateSavedJourneyData(id: entry.id, journey: filled)
        }
        journey = filled
    }

    /// The next transit leg after `leg`, plus the walking leg between them, if any.
    private func transferInfo(after leg: Leg) -> (next: Leg, walk: Leg?)? {
        guard let index = journey.legs.firstIndex(of: leg) else { return nil }
        let rest = journey.legs[(index + 1)...]
        guard let next = rest.first(where: { !$0.isWalking }) else { return nil }
        return (next, rest.prefix(while: \.isWalking).first)
    }

    @ViewBuilder
    private var issuesCard: some View {
        let issues = journey.currentIssues()
        if !issues.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 12) {
                            IconTile(systemImage: issue.isBlocking ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark.fill",
                                     color: issue.isBlocking ? .heavyDelay : .slightDelay, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.title).font(.headline)
                                Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if issues.contains(where: \.isBlocking) {
                        Button {
                            if !model.isSaved(journey) { model.save(journey) }
                            showAlternatives = true
                        } label: {
                            Label("Alternative suchen", systemImage: "arrow.triangle.branch")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.brand)
                        .controlSize(.large)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let versions = model.savedEntry(for: journey)?.previousVersions, !versions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Frühere Reisepläne", systemImage: "clock.arrow.circlepath")
                ForEach(versions) { version in
                    NavigationLink(value: ConnectionsRoute.journey(JourneyRoute(
                        journey: version.journey, finalDestination: finalDestination, readOnly: true,
                        title: "Früherer Reiseplan"))) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Ersetzt \(version.replacedAt.formatted(date: .abbreviated, time: .shortened)) · \(version.reason)",
                                  systemImage: "arrow.uturn.backward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .padding(.horizontal, 6)
                            JourneyCard(journey: version.journey).opacity(0.75)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    if let departure = journey.departure, let first = journey.legs.first {
                        VStack(alignment: .leading, spacing: 4) {
                            TimeStack(time: departure, font: .largeTitle.weight(.bold))
                            Text(first.origin.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 12)
                    if let arrival = journey.arrival, let last = journey.legs.last {
                        VStack(alignment: .trailing, spacing: 4) {
                            TimeStack(time: arrival, alignment: .trailing, font: .largeTitle.weight(.bold))
                            Text(last.destination.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                JourneySegmentBar(journey: journey)

                HStack(spacing: 8) {
                    if let duration = journey.duration {
                        InfoChip(text: duration.durationString, systemImage: "clock.fill")
                    }
                    InfoChip(text: journey.transfers == 0 ? "Direkt" : "\(journey.transfers) Umstieg\(journey.transfers == 1 ? "" : "e")",
                             systemImage: "arrow.triangle.swap")
                    if model.ticketFilter.isValid(journey) {
                        let ticket = model.settings.ticketType
                        InfoChip(text: ticket.shortName, systemImage: ticket.symbolName, tint: .punctual)
                    }
                    Spacer(minLength: 0)
                    if !readOnly {
                        Button {
                            showJourneyMap = true
                        } label: {
                            Image(systemName: "map.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .circle)
                        .accessibilityLabel("Reise auf Karte anzeigen")
                    }
                }

                if !readOnly {
                    liveActivityButton
                } else {
                    Label("Alter Plan", systemImage: "archivebox.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var shareTitle: String {
        guard let origin = journey.legs.first?.origin.displayName,
              let destination = journey.legs.last?.destination.displayName else { return "Reiseplan" }
        return "\(origin) → \(destination)"
    }

    private var liveActivityButton: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                SaveJourneyButton(journey: journey, search: search, shortLabel: true)
                if !model.tickets(for: journey).isEmpty {
                    TicketButton(tickets: model.tickets(for: journey), journey: journey)
                }
                JourneyShareButton(journey: journey, title: shareTitle)
                if model.settings.editJourneyEnabled {
                    Button {
                        showJourneyEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .circle)
                    .tint(.brand)
                    .accessibilityLabel("Reise bearbeiten")
                }
            }
            if model.isSaved(journey), model.settings.liveActivitiesEnabled {
                Label(model.liveActivities.isActive(journey)
                      ? "Läuft als Live-Aktivität"
                      : "Startet 30 Min. vor Abfahrt als Live-Aktivität",
                      systemImage: "bolt.badge.clock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let entry = model.savedEntry(for: journey),
                   model.isLiveActivityEligible(journey) || model.dismissedLiveActivityJourneyIDs.contains(entry.id) {
                    Toggle(isOn: Binding(
                        get: { !model.dismissedLiveActivityJourneyIDs.contains(entry.id)
                            && (model.manualLiveActivityJourneyID == entry.id || model.liveActivities.isActive(journey)) },
                        set: { model.setLiveActivity($0, for: entry.id) }
                    )) {
                        Label("Als Live-Aktivität zeigen", systemImage: "arrow.left.arrow.right.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .tint(.brand)
                }
            }
        }
    }
}

/// Shows the transfer between two transit legs: how much time there is (color-coded by comfort),
/// the platform change, and the walking time if the connection requires walking.
struct TransferRow: View {
    let from: Leg
    let to: Leg
    var walk: Leg?
    /// The journey is over: a transfer that looks missed only lacks a train's last delay (see
    /// `Journey.currentIssues`), so it isn't flagged.
    var isPast = false

    private var minutes: Int {
        Int((to.departure.best.timeIntervalSince(from.arrival.best) / 60).rounded())
    }
    private var broken: Bool { minutes < 0 && !isPast }
    private var color: Color { isPast && minutes < 0 ? .secondary : transferColor(minutes) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: walk != nil ? "figure.walk" : "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.15), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(broken ? "Umstieg nicht erreichbar" : minutes < 0 ? "Umstieg" : "Umstieg · \(minutes) min")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                if let walk {
                    Text("\(Int((walk.arrival.best.timeIntervalSince(walk.departure.best) / 60).rounded())) min Fußweg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if from.arrivalPlatform?.best != nil || to.departurePlatform?.best != nil {
                HStack(spacing: 6) {
                    endpoint(platform: from.arrivalPlatform, of: from)
                    Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    endpoint(platform: to.departurePlatform, of: to)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    /// The platform, or the line (e.g. "Bus 825") when that leg has none, so the arrow never points at nothing.
    @ViewBuilder
    private func endpoint(platform: PlatformInfo?, of leg: Leg) -> some View {
        if platform?.best != nil {
            PlatformBadge(platform: platform)
        } else {
            LineBadge(line: leg.line, size: .small)
        }
    }
}

struct LegCard: View {
    /// Shared with the trip view: show scheduled instead of live times at intermediate stops.
    @AppStorage("showPlannedTimes") private var showPlannedTimes = false
    let leg: Leg
    var transferBroken = false
    var onReplace: (() -> Void)?
    var onReplan: (() -> Void)?
    var onCheckin: (() -> Void)?
    /// The seat reserved on this train (from the journey's ticket), if any.
    var reservation: SeatReservation?

    @State private var showStops = false
    @State private var showDetails = false
    @State private var showFullTrip = false

    private var color: Color { leg.line?.product.color ?? .gray }
    private var intermediate: [Stopover] { Array(leg.stopovers.dropFirst().dropLast()) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                // A tap gesture rather than a Button, so the warning triangle inside can be its own button.
                HStack(spacing: 10) {
                    LiveTrainIconTile(route: LiveTrainRoute(leg: leg), systemImage: leg.line?.product.symbolName ?? "tram.fill",
                                      color: color, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        // Coupled trains have a long name; their series tag goes below it rather than being cut off.
                        TrainNameRow(name: leg.line?.displayName ?? "Zug") {
                            TrainSeriesTag(leg: leg)
                        }
                        if let direction = leg.directionDescription {
                            Text("Richtung \(direction)").font(.caption).foregroundStyle(.secondary).fullTextPopup("Richtung \(direction)")
                        }
                        TrainFormationLabel(leg: leg)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 10) {
                            TrainMessagesButton(messages: leg.messages)
                            if leg.cancelled {
                                InfoChip(text: "Fällt aus", systemImage: "xmark.octagon.fill", tint: .heavyDelay)
                            } else {
                                DelayPill(minutes: leg.departure.delayMinutes)
                            }
                            if leg.tripId != nil {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        CoachSequenceButton(leg: leg)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { if leg.tripId != nil { showFullTrip = true } }
                .accessibilityAddTraits(leg.tripId != nil ? .isButton : [])

                VStack(spacing: 0) {
                    TimelineNode(kind: .major, color: color, lineBelow: color) {
                        stationRow(time: leg.departure, name: leg.origin.displayName, platform: leg.departurePlatform)
                    }

                    if !intermediate.isEmpty {
                        TimelineNode(kind: .minor, color: color, lineAbove: color, lineBelow: color) {
                            Button {
                                withAnimation(.snappy) { showStops.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(intermediate.count) Zwischenhalt\(intermediate.count == 1 ? "" : "e")")
                                    Text("· \(leg.arrival.best.timeIntervalSince(leg.departure.best).durationString)")
                                    Image(systemName: "chevron.down")
                                        .rotationEffect(.degrees(showStops ? 180 : 0))
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        if showStops {
                            ForEach(intermediate) { stop in
                                TimelineNode(kind: .minor, color: color, lineAbove: color, lineBelow: color) {
                                    HStack {
                                        Text(stop.station.displayName).font(.caption).expandsOnTap()
                                        if stop.isAdditional {
                                            InfoChip(text: "Zusatzhalt", systemImage: "plus.circle.fill", tint: .brand)
                                        }
                                        Spacer()
                                        if let time = stop.departure ?? stop.arrival {
                                            Button {
                                                withAnimation(.snappy) { showPlannedTimes.toggle() }
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Text((showPlannedTimes ? time.planned : time.best).timeString)
                                                        .font(.caption.monospacedDigit())
                                                    // Always shown once live data exists, so an on-time (or early)
                                                    // stop is visibly live. Bracketed while the shown time already
                                                    // includes it; plain next to the scheduled time.
                                                    if let minutes = time.delayMinutes {
                                                        let text = minutes >= 0 ? "+\(minutes)" : "\(minutes)"
                                                        Text(showPlannedTimes ? text : "(\(text))")
                                                            .font(.caption2.weight(.bold).monospacedDigit())
                                                    }
                                                }
                                                .foregroundStyle(delayColor(time.delayMinutes))
                                                .contentShape(.rect)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .strikethrough(stop.cancelled)
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    TimelineNode(kind: .major, color: color, lineAbove: color) {
                        stationRow(time: leg.arrival, name: leg.destination.displayName, platform: leg.arrivalPlatform)
                    }
                }

                if transferBroken {
                    RemarkRow(text: "Wegen Verspätung klappt dieser Umstieg nicht mehr.")
                }
                ForEach(leg.remarks, id: \.self) { RemarkRow(text: $0) }

                if let reservation {
                    ReservationRow(reservation: reservation)
                }

                if leg.line?.operatorName != nil || onReplace != nil || onReplan != nil || onCheckin != nil {
                    Button {
                        withAnimation(.snappy) { showDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showDetails ? "Weniger" : "Mehr")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showDetails ? 180 : 0))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showDetails {
                        if leg.line?.operatorName != nil {
                            TrainOperatorsLabel(source: .leg(leg))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if onReplace != nil || onReplan != nil || onCheckin != nil {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                      spacing: 10) {
                                if let onReplace {
                                    ActionTileButton(title: "Anderer Zug", systemImage: "arrow.left.arrow.right", tint: .primary, action: onReplace)
                                }
                                if let onReplan {
                                    ActionTileButton(title: "Ausstieg wechseln", systemImage: "arrow.down.right.circle.fill", tint: .brand, action: onReplan)
                                }
                                if let onCheckin {
                                    ActionTileButton(title: "Träwelling", systemImage: "checkmark.seal.fill", tint: .brand, action: onCheckin)
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showFullTrip) {
            LegTripSheet(leg: leg)
        }
    }

    private func stationRow(time: TimeInfo, name: String, platform: PlatformInfo?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TimeStack(time: time, cancelled: leg.cancelled, font: .headline)
                .frame(width: 54, alignment: .leading)
            Text(name)
                .font(.headline)
                .fullTextPopup(name, lines: 2)
            Spacer()
            PlatformBadge(platform: platform)
        }
    }
}

struct AlternativeTrainsSheet: View {
    let leg: Leg
    /// The legs replacing `leg`: one for a direct train, several for a connection with transfers.
    let onSelect: ([Leg]) async throws -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var alternatives: [Leg] = []
    @State private var connections: [Journey] = []
    @State private var isLoading = true
    @State private var applyingID: String?
    @State private var onlyValidTicket = false
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                IconTile(systemImage: "arrow.left.arrow.right", color: .brand, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(leg.origin.displayName) → \(leg.destination.displayName)")
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2)
                                    Text("Aktuell: \(leg.line?.name ?? "Zug") um \(leg.departure.planned.timeString)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            Toggle(isOn: $onlyValidTicket) {
                                Label(model.settings.ticketType.filterTitle, systemImage: model.settings.ticketType.symbolName)
                                    .font(.subheadline.weight(.medium))
                            }
                            .tint(.brand)
                        }
                    }

                    if let error {
                        ErrorBanner(error: error)
                    }

                    if !alternatives.isEmpty {
                        SectionHeader(title: "Züge auf dieser Strecke", systemImage: "tram.fill",
                                      trailing: "30 Min. vorher bis 3 Std. nachher")
                            .padding(.top, 6)
                    }

                    ForEach(alternatives) { alternative in
                        Button {
                            apply([alternative], id: alternative.id)
                        } label: {
                            AlternativeRow(leg: alternative, current: leg, isApplying: applyingID == alternative.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingID != nil)
                    }

                    if !connections.isEmpty {
                        SectionHeader(title: "Mit Umstieg", systemImage: "arrow.triangle.swap")
                            .padding(.top, 6)
                    }

                    ForEach(connections) { connection in
                        Button {
                            apply(connection.legs, id: connection.id)
                        } label: {
                            JourneyCard(journey: connection)
                                .overlay(alignment: .topTrailing) {
                                    if applyingID == connection.id { ProgressView().padding(14) }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingID != nil)
                    }
                }
                .padding()
            }
            .background { AppBackground() }
            .overlay {
                if isLoading {
                    ProgressView("Suche Züge …")
                } else if alternatives.isEmpty, connections.isEmpty, error == nil {
                    ContentUnavailableView("Keine anderen Züge", systemImage: "tram.fill",
                                           description: Text("Gerade fährt kein anderer Zug von \(leg.origin.displayName) nach \(leg.destination.displayName)."))
                }
            }
            .navigationTitle("Anderen Zug wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .task(id: onlyValidTicket) { await load() }
            .onAppear { onlyValidTicket = model.settings.ticketFilterByDefault }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let filter = onlyValidTicket ? model.ticketFilter : nil
        let picker = model.trainPicker, leg = leg
        // Both lists load together; one failing still shows the other.
        async let direct = picker.alternatives(for: leg, ticketFilter: filter)
        async let withTransfers = picker.connections(for: leg, ticketFilter: filter)
        var failure: Error?
        var foundDirect: [Leg] = [], foundWithTransfers: [Journey] = []
        do { foundDirect = try await direct } catch { failure = error }
        do { foundWithTransfers = try await withTransfers } catch { failure = failure ?? error }
        guard !Task.isCancelled, !(failure is CancellationError) else { return }
        alternatives = foundDirect
        connections = foundWithTransfers
        error = foundDirect.isEmpty && foundWithTransfers.isEmpty ? failure : nil
    }

    private func apply(_ legs: [Leg], id: String) {
        applyingID = id
        Task {
            defer { applyingID = nil }
            do {
                try await onSelect(legs)
                dismiss()
            } catch {
                self.error = error
            }
        }
    }
}

struct AlternativeRow: View {
    let leg: Leg
    let current: Leg
    var isApplying = false

    var body: some View {
        let duration = leg.arrival.best.timeIntervalSince(leg.departure.best)
        let difference = Int((duration - current.arrival.best.timeIntervalSince(current.departure.best)) / 60)
        Card(padding: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    LineBadge(line: leg.line)
                    HStack(spacing: 8) {
                        TimeStack(time: leg.departure, font: .headline)
                        Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        TimeStack(time: leg.arrival, font: .headline)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(duration.compactDuration).font(.subheadline.weight(.semibold))
                    if difference != 0 {
                        Text(difference > 0 ? "+\(difference) min" : "\(difference) min")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(difference > 0 ? Color.slightDelay : Color.punctual)
                    }
                }
                if isApplying {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

#Preview("Reiseplan-Teilstrecke") {
    ScrollView {
        VStack(spacing: 16) {
            LegCard(leg: PreviewData.firstLeg, onReplace: {}, onReplan: {}, onCheckin: {})
            TransferRow(from: PreviewData.firstLeg, to: PreviewData.secondLeg, walk: PreviewData.walk)
            LegCard(leg: PreviewData.secondLeg, onReplace: {}, onCheckin: {})
            AlternativeRow(leg: PreviewData.secondLeg, current: PreviewData.firstLeg)
        }
        .padding()
    }
    .background { AppBackground() }
    .environment(AppModel())
}

/// Finds a new way to the destination after a missed transfer or cancellation.
struct AlternativeJourneySheet: View {
    let entry: SavedJourney
    let onApply: (Journey) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var alternatives: [Journey] = []
    @State private var isLoading = true
    @State private var error: Error?

    /// Legs that still work, and where/when to continue from.
    private var restart: (keep: [Leg], from: Station, date: Date, reason: String)? {
        let legs = entry.journey.legs
        let transit = entry.journey.transitLegs
        guard let destination = legs.last?.destination else { return nil }
        _ = destination
        for issue in entry.journey.connectionIssues() where issue.isBlocking {
            switch issue {
            case .transferMissed(let at, let arrivingLine, _, _):
                guard let arriving = transit.first(where: { $0.line?.name == arrivingLine && $0.destination.name == at }),
                      let index = legs.firstIndex(of: arriving) else { continue }
                return (Array(legs[...index]), arriving.destination, arriving.arrival.best, issue.title)
            case .legCancelled(let line, let from, _):
                guard let cancelled = transit.first(where: { $0.line?.name == line && $0.origin.name == from }),
                      let index = legs.firstIndex(of: cancelled) else { continue }
                return (Array(legs[..<index]), cancelled.origin, cancelled.departure.planned, issue.title)
            case .transferAtRisk:
                continue
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let restart, let destination = entry.journey.legs.last?.destination {
                        Card {
                            HStack(spacing: 12) {
                                IconTile(systemImage: "arrow.triangle.branch", color: .brand, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ab \(restart.from.displayName)").font(.headline)
                                    Text("nach \(destination.displayName), frühestens \(restart.date.timeString)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let error { ErrorBanner(error: error) }
                    ForEach(alternatives) { alternative in
                        Button {
                            apply(alternative)
                        } label: {
                            JourneyCard(journey: alternative)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Deinen alten Plan findest du weiter unter „Frühere Reisepläne“.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding()
            }
            .background { AppBackground() }
            .overlay {
                if isLoading {
                    ProgressView("Suche Alternativen …")
                } else if alternatives.isEmpty, error == nil {
                    ContentUnavailableView("Keine Alternativen gefunden", systemImage: "tram.fill")
                }
            }
            .navigationTitle("Alternative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        defer { isLoading = false }
        guard let restart, let destination = entry.journey.legs.last?.destination else {
            error = TransitError.notFound("Problemstelle")
            return
        }
        do {
            let page = try await model.provider.journeys(JourneyQuery(
                from: restart.from, to: destination, date: restart.date.addingTimeInterval(2 * 60)))
            var results = page.journeys.filter { !$0.connectionIssues().contains(where: \.isBlocking) }
            if model.settings.ticketFilterByDefault { results = results.filter(model.ticketFilter.isValid) }
            alternatives = results
        } catch {
            self.error = error
        }
    }

    private func apply(_ alternative: Journey) {
        guard let restart else { return }
        let combined = Journey(legs: restart.keep + alternative.legs, source: entry.journey.source)
        model.replaceSaved(id: entry.id, with: combined, reason: restart.reason)
        onApply(combined)
        dismiss()
    }
}
