import BetterBahnKit
import SwiftUI

struct JourneyResultsView: View {
    let search: ConnectionSearch

    @Environment(AppModel.self) private var model
    @State private var searchDate: Date
    @State private var journeys: [Journey] = []
    @State private var earlierCursor: String?
    @State private var laterCursor: String?
    @State private var hiddenCount = 0
    @State private var source: DataSource?
    @State private var isLoading = false
    @State private var loadingMore = false
    @State private var error: Error?
    @State private var showTrainSheet = false
    @State private var showTimePicker = false
    /// Trains the route has to use, in ride order. Adding another one keeps the existing ones.
    @State private var requirements: [TrainRequirement] = []
    @State private var plan: TrainRoutePlan?
    @State private var planError: Error?
    @State private var isPlanning = false
    /// Results on screen with their live times, loaded after the list shows (see `checkLive`).
    @State private var liveResults: [String: Journey] = [:]

    /// A route counts as noticeably slower than the free choice from this much extra travel time.
    private static let slowRouteThreshold: TimeInterval = 60 * 60

    init(search: ConnectionSearch) {
        self.search = search
        _searchDate = State(initialValue: search.date)
    }

    /// Only routes that fulfil every train requirement are shown once one is set.
    private var visibleJourneys: [Journey] {
        requirements.isEmpty ? journeys : (plan?.journeys ?? []).removingDuplicateIDs()
    }

    /// Fastest connection without any train requirement, for comparison.
    private var baselineDuration: TimeInterval? {
        journeys.filter { !$0.isCancelled }.compactMap(\.duration).min()
    }

    /// How much longer the best required route takes than the free choice, if it's worth warning about.
    private var extraTravelTime: TimeInterval? {
        guard let baseline = baselineDuration, let forced = plan?.best?.duration else { return nil }
        let extra = forced - baseline
        return extra >= Self.slowRouteThreshold ? extra : nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                header

                if let error {
                    ErrorBanner(error: error)
                }

                if model.settings.trainChoiceEnabled {
                    trainBar
                }

                if !requirements.isEmpty {
                    requirementList

                    if isPlanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Suche Verbindungen mit deinen Zügen …")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }

                    if let planError {
                        ErrorBanner(error: planError)
                    }

                    if let extraTravelTime {
                        warningBanner("Mit diesem Zug bist du \(extraTravelTime.compactDuration) länger unterwegs.")
                    }

                    if plan?.breaksBoardingRules == true {
                        warningBanner("An einem gewählten Halt ist Ein- oder Aussteigen laut Fahrplan nicht erlaubt.")
                    }

                    if !visibleJourneys.isEmpty {
                        SectionHeader(title: "Routen mit \(requirements.count == 1 ? "diesem Zug" : "diesen Zügen")",
                                      systemImage: "pin.fill")
                    }
                }

                if requirements.isEmpty, earlierCursor != nil {
                    pageButton("Frühere Verbindungen", systemImage: "chevron.up") {
                        await load(cursor: earlierCursor, prepend: true)
                    }
                }

                ForEach(Array(visibleJourneys.enumerated()), id: \.element.id) { index, result in
                    let journey = liveResults[result.id].map { JourneyRefresher.keepingPlatforms(of: result, in: $0) } ?? result
                    NavigationLink(value: ConnectionsRoute.journey(JourneyRoute(journey: journey, finalDestination: search.to, search: search))) {
                        JourneyCard(journey: journey)
                            .overlay {
                                if !requirements.isEmpty, index == 0 {
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .strokeBorder(Color.brand, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .task { await checkLive(result) }
                }

                if requirements.isEmpty, laterCursor != nil {
                    pageButton("Spätere Verbindungen", systemImage: "chevron.down") {
                        await load(cursor: laterCursor, prepend: false)
                    }
                }

                VStack(spacing: 8) {
                    if hiddenCount > 0, requirements.isEmpty {
                        InfoChip(text: "\(hiddenCount) nicht mit \(model.settings.ticketType.shortName) nutzbar", systemImage: "eye.slash.fill")
                    }
                    if source == .transitous {
                        SourceNotice()
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .tabBarSafePadding()
        .background { AppBackground() }
        .overlay {
            if isLoading, journeys.isEmpty {
                ProgressView("Suche Verbindungen …")
            } else if !isLoading, !isPlanning, visibleJourneys.isEmpty, error == nil, planError == nil {
                ContentUnavailableView("Keine Verbindungen", systemImage: "tram.fill",
                                       description: Text(requirements.isEmpty
                                                         ? "Versuch eine andere Uhrzeit oder weniger Filter."
                                                         : "Mit diesen Zügen haben wir keine Verbindung gefunden."))
            }
        }
        .navigationTitle("Verbindungen")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTrainSheet) {
            TrainNumberSheet(search: search, suggestions: trainSuggestions, defaultBoarding: nextBoardingDefault,
                             stations: trainSearchStations, date: nextBoardingTime) { requirement in
                requirements.append(requirement)
                Task { await replan() }
            }
        }
        // Only the first time: coming back from a connection keeps the list (and the trains added below).
        .task { if journeys.isEmpty, error == nil { await load(cursor: nil, prepend: false) } }
        .refreshable {
            await load(cursor: nil, prepend: false)
            await replan()
        }
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Color.slightDelay)
            Text(text)
                .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.slightDelay.opacity(0.1), in: .rect(cornerRadius: 14, style: .continuous))
    }


    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(search.from.displayName).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(search.to.displayName).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !search.via.isEmpty {
                    Text("über " + search.via.map(viaLabel).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    showTimePicker = true
                } label: {
                    InfoChip(text: searchDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                             systemImage: search.isArrival ? "arrow.down.right" : "arrow.up.right")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showTimePicker) {
                    timePickerPopover
                }
                if search.onlyValidTicket {
                    let ticket = model.settings.ticketType
                    InfoChip(text: ticket.shortName, systemImage: ticket.symbolName, tint: .brand)
                }
                if let maxTransfers = search.maxTransfers {
                    InfoChip(text: maxTransfers == 0 ? "Direkt" : "≤ \(maxTransfers) Umstieg\(maxTransfers == 1 ? "" : "e")",
                             systemImage: "arrow.triangle.swap", tint: .brand)
                }
                if search.products != Set(Product.allCases) {
                    InfoChip(text: "Verkehrsmittel gefiltert", systemImage: "line.3.horizontal.decrease", tint: .brand)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private var timePickerPopover: some View {
        VStack(spacing: 12) {
            DatePicker("Zeit", selection: $searchDate)
                .datePickerStyle(.graphical)
                .tint(.brand)
            HStack {
                Button {
                    searchDate = .now
                } label: {
                    Label("Jetzt", systemImage: "clock.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Fertig") {
                    showTimePicker = false
                    Task { await reload() }
                }
                .buttonStyle(.glassProminent)
            }
            .tint(.brand)
        }
        .padding()
        .presentationCompactAdaptation(.sheet)
        .presentationDetents([.height(500)])
    }

    private var trainBar: some View {
        HStack(spacing: 10) {
            Button {
                showTrainSheet = true
            } label: {
                Label(requirements.isEmpty ? "Bestimmten Zug wählen" : "Weiteren Zug vorgeben", systemImage: "number")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(.brand)

            if !requirements.isEmpty {
                Button {
                    withAnimation(.snappy) { resetRequirements() }
                } label: {
                    Label("Zurücksetzen", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.iconOnly)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Alle Züge entfernen")
            }
        }
    }

    /// The trains the route must use, each removable on its own.
    private var requirementList: some View {
        VStack(spacing: 8) {
            ForEach(requirements) { requirement in
                HStack(spacing: 10) {
                    IconTile(systemImage: "tram.fill", color: .brand, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan?.resolvedNames[requirement.id] ?? requirement.trainName.uppercased())
                            .font(.subheadline.weight(.semibold))
                        Text(requirementSubtitle(requirement))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        withAnimation(.snappy) { remove(requirement) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zug entfernen")
                }
                .padding(10)
                .background(Color.card, in: .rect(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func requirementSubtitle(_ requirement: TrainRequirement) -> String {
        if let exit = requirement.exit {
            return "ab \(requirement.boarding.displayName) → \(exit.displayName)"
        }
        return "ab \(requirement.boarding.displayName) → schnellster Weg"
    }

    /// A new requirement usually continues where the last one ends: its exit, else where the planned
    /// route leaves that train (#225: not the search's origin, where the next train doesn't call).
    private var nextBoardingDefault: Station {
        guard let last = requirements.last else { return search.from }
        if let exit = last.exit { return exit }
        return lastRequiredLeg?.destination ?? last.boarding
    }

    /// When the traveller stands at `nextBoardingDefault`, as far as the plan knows.
    private var nextBoardingTime: Date {
        lastRequiredLeg?.arrival.best ?? searchDate
    }

    /// The leg of the best planned route that rides the last required train.
    private var lastRequiredLeg: Leg? {
        guard let last = requirements.last, let best = plan?.best else { return nil }
        let name = plan?.resolvedNames[last.id]
        return best.transitLegs.last { leg in
            if let tripId = last.tripId { return leg.tripId == tripId }
            return name != nil && leg.line?.name == name
        }
    }

    /// Where a required train could be boarded: the planned route's stations, the origin, then the
    /// stations the results change at.
    private var trainSearchStations: [Station] {
        let planned = (plan?.journeys ?? []).prefix(2).flatMap { $0.transitLegs.map(\.origin) }
        let found = journeys.prefix(4).flatMap { $0.transitLegs.map(\.origin) }
        return planned + [search.from] + found
    }

    private func remove(_ requirement: TrainRequirement) {
        requirements.removeAll { $0.id == requirement.id }
        if requirements.isEmpty {
            plan = nil
            planError = nil
        } else {
            Task { await replan() }
        }
    }

    private func resetRequirements() {
        requirements = []
        plan = nil
        planError = nil
    }

    private func viaLabel(_ waypoint: ViaWaypoint) -> String {
        waypoint.minStayMinutes > 0 ? "\(waypoint.station.displayName) (≥ \(waypoint.minStayMinutes) Min.)" : waypoint.station.displayName
    }

    /// Long-distance trains from the loaded results, as quick picks.
    private var trainSuggestions: [String] {
        var names: [String] = []
        for leg in journeys.flatMap(\.transitLegs) where leg.line?.product.isTrain == true {
            if let name = leg.line?.name, !names.contains(name) { names.append(name) }
        }
        return Array(names.prefix(12))
    }

    private func pageButton(_ title: String, systemImage: String, action: @escaping () async -> Void) -> some View {
        Button {
            loadingMore = true
            Task {
                await action()
                loadingMore = false
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(loadingMore)
    }

    /// Re-runs the search from scratch, e.g. after the user picks a new time.
    private func reload() async {
        journeys = []
        earlierCursor = nil
        laterCursor = nil
        hiddenCount = 0
        await load(cursor: nil, prepend: false)
        // Train requirements survive a new time – they're only cleared by the reset button.
        await replan()
    }

    /// Rebuilds the routes that ride every required train. Keeps the previous plan on failure only
    /// long enough to surface the error – an unfulfillable requirement must not show stale routes.
    private func replan() async {
        guard !requirements.isEmpty else { return }
        isPlanning = true
        defer { isPlanning = false }
        do {
            var result = try await model.trainRoutePlanner.plan(
                requirements, from: search.from, to: search.to, date: searchDate)
            if search.onlyValidTicket {
                // Don't leave the user with nothing if the forced train itself isn't valid with the ticket.
                let valid = result.journeys.filter(model.ticketFilter.isValid)
                if !valid.isEmpty { result.journeys = valid }
            }
            withAnimation(.snappy) {
                plan = result
                planError = nil
            }
        } catch is CancellationError {
        } catch {
            plan = nil
            planError = error
        }
    }

    private func load(cursor: String?, prepend: Bool) async {
        isLoading = true
        defer { isLoading = false }
        // First page: which trains call at both ends is looked up alongside the search, so detours are
        // gone and the expert option's trains are there about when the results show.
        let lookup: Task<DetourLookup, Never>? = cursor == nil && search.via.isEmpty ? {
            let start = search.isArrival ? searchDate.addingTimeInterval(-Self.lookupWindow) : searchDate
            let addingRestricted = model.settings.ignoreBoardingRulesEnabled
            return Task { await detourLookup(start: start, end: start.addingTimeInterval(2 * Self.lookupWindow),
                                             addingRestricted: addingRestricted) }
        }() : nil
        do {
            var result: [Journey]
            var page: JourneyPage?
            if search.via.isEmpty {
                let loaded = try await model.provider.journeys(JourneyQuery(
                    from: search.from, to: search.to, date: searchDate, isArrival: search.isArrival, cursor: cursor,
                    products: search.products, maxTransfers: search.maxTransfers))
                result = loaded.journeys
                page = loaded
            } else {
                // Routed via search has no cursor-based paging – it's a single chained search.
                var planner = ViaRoutePlanner(provider: model.provider, products: search.products)
                if model.settings.ignoreBoardingRulesEnabled {
                    // Each part of the route may also use trains you may not board or leave at its ends.
                    let picker = model.trainPicker
                    let window = Self.lookupWindow
                    planner.extraSegmentJourneys = { from, to, date in
                        let calls = await picker.stationCalls(from: from, to: to, start: date, end: date.addingTimeInterval(window))
                        return await picker.journeysIgnoringBoardingRules(from: from, to: to, calls: calls)
                    }
                }
                result = try await planner.journeys(from: search.from, to: search.to, via: search.via, date: searchDate)
                // Products are applied per leg by the planner; only the overall transfer limit is left.
                if let maxTransfers = search.maxTransfers {
                    result = result.filter { $0.transfers <= maxTransfers }
                }
            }
            if search.onlyValidTicket {
                let filter = model.ticketFilter
                let before = result.count
                result = result.filter(filter.isValid)
                hiddenCount += before - result.count
            }
            source = page?.source ?? model.provider.source
            // Wait a moment for the lookup, so the list doesn't change right after it shows.
            let early = await lookup?.value(within: .milliseconds(1500))
            if let early { result = applying(early, to: result) }
            if cursor == nil {
                journeys = result.removingDuplicateIDs().removingSameTrainDuplicates()
                // The first connection is the one most likely opened next: have its live data ready.
                if let first = result.first(where: { ($0.departure?.best ?? .distantFuture) > .now }) {
                    model.prepareLiveData(for: first)
                }
                earlierCursor = page?.earlierCursor
                laterCursor = page?.laterCursor
            } else if prepend {
                journeys = (result + journeys).removingDuplicateIDs().removingSameTrainDuplicates()
                earlierCursor = page?.earlierCursor
            } else {
                journeys = (journeys + result).removingDuplicateIDs().removingSameTrainDuplicates()
                laterCursor = page?.laterCursor
            }
            error = nil
            if let lookup, early == nil {
                let found = await lookup.value
                if !Task.isCancelled { withAnimation(.snappy) { journeys = applying(found, to: journeys) } }
            } else if cursor != nil, search.via.isEmpty, !result.isEmpty {
                // A further page: its own window, detours and markings only.
                let start = result.compactMap(\.departure?.planned).min() ?? searchDate
                let end = result.compactMap(\.arrival?.planned).max() ?? start
                let found = await detourLookup(start: start, end: end, addingRestricted: false)
                if !Task.isCancelled { withAnimation(.snappy) { journeys = applying(found, to: journeys) } }
            }
            await fillMissingPlatforms(in: result)
        } catch is CancellationError {
            lookup?.cancel()
        } catch {
            lookup?.cancel()
            self.error = error
        }
    }

    private static let lookupWindow: TimeInterval = 180 * 60

    /// What `detourLookup` found: which trains call at both ends, and the expert option's extra trains.
    struct DetourLookup: Sendable {
        var calls: StationCalls
        var extra: [Journey]
    }

    /// Looks up the trains calling at the origin and destination between `start` and `end`, to hide
    /// routes that change onto a train also calling at the origin, or leave one also calling at the
    /// destination (e.g. Berlin Hbf → Halle → back to Gesundbrunnen on an ICE that stops at Hbf too).
    /// Via searches keep those, since there the change is wanted. With the expert option "Nur
    /// Ein-/Ausstieg ignorieren" it also finds the direct trains the timetable doesn't let you board or
    /// leave here, which the search itself never offers, and trains you may not board here that end
    /// short of the destination, with a connection on from where they stop.
    private func detourLookup(start: Date, end: Date, addingRestricted: Bool) async -> DetourLookup {
        let picker = model.trainPicker
        let calls = await picker.stationCalls(from: search.from, to: search.to, start: start, end: end)
        guard addingRestricted else { return DetourLookup(calls: calls, extra: []) }
        // Also trains you may not board here that don't go all the way, with a connection from where they stop.
        let query = JourneyQuery(from: search.from, to: search.to, date: start, products: search.products,
                                 maxTransfers: search.maxTransfers)
        async let continuing = picker.journeysContinuingFromRestrictedTrains(query, calls: calls, end: end)
        let direct = await picker.journeysIgnoringBoardingRules(from: search.from, to: search.to, calls: calls)
        var extra = (direct + (await continuing))
            .filter { journey in
                journey.transitLegs.allSatisfy { search.products.contains($0.line?.filterProduct ?? .other) }
            }
        if search.onlyValidTicket {
            let filter = model.ticketFilter
            extra = extra.filter(filter.isValid)
        }
        return DetourLookup(calls: calls, extra: extra)
    }

    private func applying(_ lookup: DetourLookup, to list: [Journey]) -> [Journey] {
        let kept = list.filter { !lookup.calls.isDetour($0) }.map(lookup.calls.marking)
        let direct = StationCalls.directTripIds(kept)
        let extra = lookup.extra.filter { journey in
            guard !(journey.transitLegs.first?.tripId.map(direct.contains) ?? false) else { return false }
            // Not worth showing when a normal connection leaves no earlier and arrives no later.
            guard let departure = journey.departure?.best, let arrival = journey.arrival?.best else { return true }
            return !kept.contains { ($0.departure?.best ?? .distantPast) >= departure && ($0.arrival?.best ?? .distantFuture) <= arrival }
        }
        var updated = (kept + extra).removingDuplicateIDs()
        if !extra.isEmpty {
            updated.sort { ($0.departure?.planned ?? .distantFuture) < ($1.departure?.planned ?? .distantFuture) }
        }
        return updated
    }

    /// Loads the live times of a result once it scrolls into view, so a missed transfer or a
    /// cancellation the search didn't know yet shows as "Nicht möglich" on its card. The list never
    /// waits for it; cards just update when the data is in.
    private func checkLive(_ journey: Journey) async {
        guard liveResults[journey.id] == nil, JourneyRefresher.isWorthLiveCheck(journey) else { return }
        let live = await model.journeyRefresher.refreshEnds(journey)
        // Scrolled away before it loaded: the lookups were cancelled, so this isn't live data.
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) { liveResults[journey.id] = live }
    }

    /// Transitous leaves some trains' Gleis out (whole regional feeds, but now and then ICEs and RJs
    /// too); fills those in from DB's own schedule once the results are already on screen.
    private func fillMissingPlatforms(in loaded: [Journey]) async {
        guard let timetables = model.timetablesClient else { return }
        await withTaskGroup(of: Journey?.self) { group in
            for journey in loaded where journey.transitLegs.contains(where: {
                $0.departurePlatform?.best == nil || $0.arrivalPlatform?.best == nil
            }) {
                group.addTask {
                    let filled = await timetables.fillMissingPlatforms(in: journey)
                    return filled == journey ? nil : filled
                }
            }
            for await filled in group {
                guard let filled, let index = journeys.firstIndex(where: { $0.id == filled.id }) else { continue }
                journeys[index] = filled
            }
        }
    }
}

struct JourneyCard: View {
    let journey: Journey

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    if let departure = journey.departure {
                        TimeStack(time: departure, cancelled: journey.isCancelled, font: .title2.weight(.bold))
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        if let duration = journey.duration {
                            Text(duration.compactDuration)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let arrival = journey.arrival {
                        TimeStack(time: arrival, cancelled: journey.isCancelled, alignment: .trailing, font: .title2.weight(.bold))
                    }
                }

                JourneySegmentBar(journey: journey)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(journey.transitLegs.enumerated()), id: \.element.id) { index, leg in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            LineBadge(line: leg.line)
                        }
                    }
                }

                HStack(spacing: 8) {
                    InfoChip(text: journey.transfers == 0 ? "Direkt" : "\(journey.transfers) Umstieg\(journey.transfers == 1 ? "" : "e")",
                             systemImage: journey.transfers == 0 ? "arrow.right" : "arrow.triangle.swap")
                    if let platform = journey.transitLegs.first?.departurePlatform?.best {
                        InfoChip(text: "Gleis \(platform)", systemImage: "signpost.right.fill",
                                 tint: journey.transitLegs.first?.departurePlatform?.hasChanged == true ? .heavyDelay : .secondary)
                    }
                    Spacer()
                    if journey.isCancelled {
                        InfoChip(text: "Fällt aus", systemImage: "xmark.octagon.fill", tint: .heavyDelay)
                    } else if journey.transitLegs.contains(where: { $0.stopovers.first?.access.allowsBoarding == false }) {
                        InfoChip(text: "Kein Einstieg", systemImage: "arrow.down.right.circle.fill", tint: .slightDelay)
                    } else if journey.transitLegs.contains(where: { $0.stopovers.last?.access.allowsAlighting == false }) {
                        InfoChip(text: "Kein Ausstieg", systemImage: "arrow.up.right.circle.fill", tint: .slightDelay)
                    } else if journey.currentIssues().contains(where: \.isBlocking) {
                        InfoChip(text: "Nicht möglich", systemImage: "exclamationmark.triangle.fill", tint: .heavyDelay)
                    } else if !journey.currentIssues().isEmpty {
                        InfoChip(text: "Knapp", systemImage: "exclamationmark.triangle.fill", tint: .slightDelay)
                    } else if journey.legs.contains(where: { $0.messages.containsDelayReason }) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.heavyDelay)
                    } else if journey.legs.contains(where: { !$0.remarks.isEmpty || !$0.messages.isEmpty }) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.slightDelay)
                    }
                }
            }
        }
    }
}

/// Wrapping row of tappable line chips.
struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        ChipFlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    onTap(item)
                } label: {
                    Text(item)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.card, in: .capsule)
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

#Preview("Ergebniskarten") {
    ScrollView {
        VStack(spacing: 12) {
            JourneyCard(journey: PreviewData.journey)
            JourneyCard(journey: PreviewData.directJourney)
            JourneyCard(journey: PreviewData.regionalJourney)
        }
        .padding()
    }
    .background { AppBackground() }
}

private extension Task where Failure == Never {
    /// The task's result if it's ready within `limit`, else nil (the task keeps running).
    func value(within limit: Duration) async -> Success? {
        await withTaskGroup(of: Success?.self) { group in
            group.addTask { await self.value }
            group.addTask { try? await Task<Never, Never>.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
