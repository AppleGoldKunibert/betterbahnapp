import BetterBahnKit
import SwiftUI

/// Full route of a train from the station board. Pick where you get on/off to check in
/// or start a Live Activity.
struct TripView: View {
    let entry: BoardEntry
    /// Picks the board's station as where you get on (or off); off when the train was found by its
    /// number, where that station is just where it was looked up.
    var selectsStation = true

    @Environment(AppModel.self) private var model
    @State private var trip: Trip?
    @State private var boardingID: String?
    @State private var exitID: String?
    @State private var error: Error?
    /// The coupled train whose stops are shown instead of this one's (nil: this one).
    @State private var shownTripId: String?
    /// Where you got on/off before switching trains, picked again in the other one.
    @State private var keptStops: (boarding: Station?, exit: Station?)?
    /// Laps of a looping train (Ringbahn) loaded before / after the one the board opened, by "Vorherige /
    /// Nächste Runde laden".
    @State private var extraLapsBefore = 0
    @State private var extraLapsAfter = 0
    @State private var isLoadingLap = false
    @Environment(\.appDesign) private var design

    private var tripId: String { shownTripId ?? entry.tripId }

    /// Where the loaded laps are remembered (see `LoadedLaps`).
    private var lapsKey: String { LoadedLaps.key(tripId: entry.tripId, station: entry.station, near: entry.time.planned) }

    private var ownDirection: String? { entry.kind == .departures ? entry.otherEnd : nil }

    private var runs: [Line.CoupledTrain] { entry.line.runs(ownDirection: ownDirection, ownTripId: entry.tripId) }

    var body: some View {
        ScrollView {
            if !runs.isEmpty {
                CoupledTrainPicker(trains: runs, selection: Binding(get: { tripId }, set: { switchTrain(to: $0) }))
                    .padding(.horizontal)
            }
            if trip == nil, error == nil {
                TripLoadingView()
            }
            VStack(spacing: 16) {
                if let error {
                    ErrorBanner(error: error)
                }
                if let trip {
                    TripContent(trip: trip, highlight: selectsStation ? entry.station : nil, boardingID: $boardingID, exitID: $exitID,
                                onLoadPreviousLap: { loadLap(before: 1) }, onLoadNextLap: { loadLap(after: 1) },
                                isLoadingLap: isLoadingLap)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
            .readableWidth()
        }
        .background { AppBackground() }
        .safeAreaInset(edge: .bottom) {
            if let leg = selectedLeg {
                actionBar(leg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedLeg?.id)
        .navigationTitle(entry.line.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Seen before: in the first frame, without the spinner in between.
            if trip == nil, let seen = model.liveTrips.value(for: tripId) { show(seen) }
        }
        .task(id: tripId) {
            if tripId == entry.tripId {
                let remembered = model.openLoadedLaps(lapsKey, tripId: entry.tripId)
                extraLapsBefore = remembered.before
                extraLapsAfter = remembered.after
            }
            // Seen before: its last live data right away, refreshed below.
            if trip == nil, let seen = model.liveTrips.value(for: tripId) { show(seen) }
            await load()
            await autoRefresh(tripId: tripId)
        }
        .onDisappear { model.closeLoadedLaps(lapsKey) }
        .refreshable {
            await TimetablesClient.invalidateDelays()
            await load()
        }
    }

    /// Re-loads every 5 minutes while this trip belongs to a saved journey.
    private func autoRefresh(tripId: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: AppModel.realtimeRefreshInterval)
            guard !Task.isCancelled else { return }
            if model.isTripSaved(tripId) { await load() }
        }
    }

    private var selectedLeg: Leg? {
        guard let trip,
              let boarding = trip.stopovers.firstIndex(where: { $0.id == boardingID }),
              let exit = trip.stopovers.firstIndex(where: { $0.id == exitID }) else { return nil }
        return trip.leg(fromIndex: boarding, toIndex: exit)
    }

    private func actionBar(_ leg: Leg) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(leg.origin.displayName).fullTextPopup(leg.origin.displayName)
                Image(systemName: "arrow.right").font(.caption.weight(.bold))
                Text(leg.destination.displayName).fullTextPopup(leg.destination.displayName)
                Spacer()
                Text(leg.arrival.best.timeIntervalSince(leg.departure.best).compactDuration)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .fontDesign(design == .fahrkarte ? .rounded : nil)
            SaveJourneyButton(journey: Journey(legs: [leg], source: leg.source))
        }
        .padding(16)
        .modifier(ActionBarSurface())
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Shows the stops of another of the coupled trains, keeping where you get on/off where it stops there too.
    private func switchTrain(to id: String) {
        guard id != tripId else { return }
        keptStops = (station(boardingID), station(exitID))
        boardingID = nil
        exitID = nil
        error = nil
        extraLapsBefore = 0
        extraLapsAfter = 0
        shownTripId = id == entry.tripId ? nil : id
        trip = nil
        if let seen = model.liveTrips.value(for: id) { show(seen) }
    }

    private func station(_ stopoverID: String?) -> Station? {
        trip?.stopovers.first { $0.id == stopoverID }?.station
    }

    private func load() async {
        let tripId = tripId
        do {
            var loaded = try await model.provider.plainTrip(id: tripId, source: entry.source)
            if tripId != entry.tripId, let train = runs.first(where: { $0.tripId == tripId }) {
                // A coupled train: it leads, this one becomes the coupled one.
                loaded.line = entry.line.riding(train, ownDirection: ownDirection, ownTripId: entry.tripId)
            } else if let name = loaded.line?.name, entry.line.alternateName == name || entry.line.coupledTrains != nil {
                // The board may have taken bahn.de's name for this train (e.g. "RJ 171" for Transitous'
                // "ICE 171"), or found the trains coupled to it; keep that rather than switching back.
                loaded.line = entry.line
            } else if loaded.line?.isUnknown ?? true, tripId == entry.tripId, !entry.line.isUnknown {
                // An extra train Transitous has no line for, which the board named ("S1" for "?").
                loaded.line = entry.line
            }
            // A ring line's trip is the vehicle's whole day: only the lap of the board's departure (or
            // arrival) is the run shown here, with the run number the board knows.
            if tripId == entry.tripId,
               let lap = loaded.lap(at: entry.station, near: entry.time.planned, arriving: entry.kind == .arrivals,
                                    extraBefore: extraLapsBefore, extraAfter: extraLapsAfter) {
                loaded = lap
                if let run = entry.line.tripNumber { loaded.line?.tripNumber = run }
            }
            guard tripId == self.tripId else { return }
            error = nil
            // Every source's live data in one go (`LiveRun`), shown as it comes: a run not seen before waits a
            // little for DB's delays so it doesn't jump from the timetable to the live times; one already showing
            // (seen before, or a reload) is the baseline, so nothing it knows goes missing meanwhile.
            let baseline = trip ?? model.liveTrips.value(for: tripId)
            let live = await model.liveRun.refresh(loaded, baseline: baseline, wholeRun: true) { partial in
                // Switched to another train meanwhile.
                guard tripId == self.tripId else { return }
                show(partial)
            }
            guard tripId == self.tripId else { return }
            show(live)
            model.rememberLive(live)
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    /// Adds the lap before / after the ones shown and loads the trip again with it.
    private func loadLap(before: Int = 0, after: Int = 0) {
        guard !isLoadingLap else { return }
        extraLapsBefore += before
        extraLapsAfter += after
        model.rememberLoadedLaps(.init(before: extraLapsBefore, after: extraLapsAfter), for: lapsKey, tripId: entry.tripId)
        isLoadingLap = true
        Task {
            await load()
            isLoadingLap = false
        }
    }

    private func show(_ loaded: Trip) {
        trip = loaded
        // A pick from a trip seen before that this one doesn't have (another lap of a ring line).
        if let id = boardingID, !loaded.stopovers.contains(where: { $0.id == id }) { boardingID = nil }
        if let id = exitID, !loaded.stopovers.contains(where: { $0.id == id }) { exitID = nil }
        guard boardingID == nil, exitID == nil else { return }
        if let keptStops {
            boardingID = keptStops.boarding.flatMap { kept in loaded.stopovers.first { $0.station.isSamePlace(as: kept) }?.id }
            exitID = keptStops.exit.flatMap { kept in loaded.stopovers.last { $0.station.isSamePlace(as: kept) }?.id }
            if boardingID != nil { return }
        }
        guard selectsStation else { return }
        let here = loaded.stopovers.first { $0.station.isSamePlace(as: entry.station) }?.id
        if entry.kind == .arrivals {
            // For arrivals the selected station is where you get off; where you got on is picked by tapping.
            exitID = here
        } else {
            boardingID = here
        }
    }
}

/// Behind the bar for the picked ride. Minimal: the card surface, lifted by a soft shadow. Fahrkarte: Liquid Glass.
private struct ActionBarSurface: ViewModifier {
    @Environment(\.appDesign) private var design

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if design == .fahrkarte {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(Color.card, in: shape)
                .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        }
    }
}

/// Spinner shown while a trip loads. Sized to the scroll view's visible area rather than laid over
/// the (still empty) scroll view, which could leave it squeezed into a corner until the trip arrived.
private struct TripLoadingView: View {
    var body: some View {
        ProgressView("Lade Fahrtverlauf …")
            .containerRelativeFrame([.horizontal, .vertical])
    }
}

/// Switches between the trains running coupled together (Doppeltraktion), to see each one's stops.
private struct CoupledTrainPicker: View {
    let trains: [Line.CoupledTrain]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Zugteil", selection: $selection) {
                ForEach(trains, id: \.tripId) { train in
                    Text(train.name).tag(train.tripId ?? "")
                }
            }
            .pickerStyle(.segmented)
            if let direction = trains.first(where: { $0.tripId == selection })?.direction {
                Text("Zugteil nach \(direction)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 8)
    }
}

/// Trip header + selectable stop timeline.
struct TripContent: View {
    let trip: Trip
    /// Shown in bold: the station the train was opened from.
    let highlight: Station?
    @Binding var boardingID: String?
    @Binding var exitID: String?
    /// When false, stops are shown read-only (e.g. viewing the full route of a leg already booked).
    var interactive = true
    /// Locks the boarding stop, so tapping only ever moves the exit (used when re-planning a
    /// journey from a train you are already on).
    var exitOnly = false
    /// Called when the user taps a stop, so callers can react to a hand-picked change only (the
    /// bindings also move when a caller seeds them itself).
    var onSelectStop: ((Stopover) -> Void)?
    /// The saved journey's leg riding this train, whose remembered Tz shows once nothing answers any more.
    var savedLeg: Leg? = nil
    /// A looping train (Ringbahn) shows one lap: these load the one before / after it, and are only shown
    /// while `trip` says there is one (`Trip.hasPreviousLap`).
    var onLoadPreviousLap: (() -> Void)? = nil
    var onLoadNextLap: (() -> Void)? = nil
    /// A lap is being loaded: the buttons wait.
    var isLoadingLap = false
    /// Tapping any stop time flips every stop between real-time and scheduled times — app-wide, and remembered.
    @AppStorage("showPlannedTimes") private var showPlannedTimes = false
    /// Set once a boarding/exit stop was picked by hand; from then on the "Tippe auf Halte" tip stays hidden.
    @AppStorage("pickedTripStop") private var pickedTripStop = false
    /// Read when the view appears, so the tip doesn't vanish (and move the stops) while picking them.
    @State private var showsStopTip = !UserDefaults.standard.bool(forKey: "pickedTripStop")
    /// The stop whose platform was tapped: its Wagenreihung is unfolded below it.
    @State private var sequenceStopID: String?
    /// Where a train run by several railways changes hands (stopover ID → operators), e.g. DB at the
    /// start and at Bad Schandau, ČD at Děčín; empty for one railway throughout.
    @State private var operatorStops: [String: [String]] = [:]
    /// Which side the platform is on at the picked exit (#394), if the offline list knows.
    @State private var exitSide: ExitSide?
    /// What past runs of this train say at the stops that matter (#316).
    @State private var statistics = TrainStatisticsModel()
    /// The platform changes of the stops ahead, shown at the stop 30 minutes before it and always at the next one.
    @State private var platformStatistics = TrainStatisticsModel()
    /// DB's occupancy forecast (#399) from the picked boarding stop to the exit, else for the whole run.
    @State private var occupancy: OccupancyForecast?
    @Environment(AppModel.self) private var model
    @Environment(\.appDesign) private var design

    private var color: Color { trip.line?.color ?? .gray }

    /// The Fahrkarte design draws the train's header as a ticket (#504).
    private var isTicket: Bool { design == .fahrkarte }

    /// Fahrkarte: names and times in the rounded type.
    private var rounded: Font.Design? { isTicket ? .rounded : nil }

    /// The time the train reaches the stop (leaves it, at the first one), which the platform hint is timed by.
    private func hintTime(_ stop: Stopover, index: Int) -> Date? {
        (index == 0 ? stop.departure : stop.arrival ?? stop.departure)?.best
    }

    /// The first stop the train hasn't reached yet.
    private var nextStopIndex: Int? {
        trip.stopovers.indices.first { index in hintTime(trip.stopovers[index], index: index).map { $0 > Date() } ?? false }
    }

    /// The upcoming stops the platform changes are looked up for: the next dozen.
    private var platformHintStops: [StatisticsStop] {
        guard let next = nextStopIndex else { return [] }
        return trip.stopovers.indices.dropFirst(next).prefix(12).map { index in
            let stop = trip.stopovers[index]
            let platform = index == 0 ? stop.departurePlatform : stop.arrivalPlatform ?? stop.departurePlatform
            return StatisticsStop(station: stop.station, role: index == 0 ? .departure : .arrival, platform: platform?.planned)
        }
    }

    /// A likely platform change at this stop: 30 minutes before the train gets there, and always at the next stop.
    private func platformChangeHint(at stop: Stopover, index: Int) -> PlatformChangeHint? {
        guard let time = hintTime(stop, index: index), time > Date(),
              index == nextStopIndex || time.timeIntervalSinceNow <= 30 * 60 else { return nil }
        let platform = index == 0 ? stop.departurePlatform : stop.arrivalPlatform ?? stop.departurePlatform
        return platformStatistics.platformChange(at: stop.station, planned: platform?.planned)
    }

    /// The day the figures are kept for: the train's first departure.
    private var statisticsDate: Date { trip.stopovers.first?.departure?.planned ?? .now }

    /// Where the experience values apply: the stops picked to get on and off, else the station the train
    /// was opened from, else the whole run.
    private var statisticsStops: [StatisticsStop] {
        func stop(_ stopover: Stopover, _ role: StatisticsStop.Role) -> StatisticsStop {
            let platform = role == .departure ? stopover.departurePlatform : stopover.arrivalPlatform
            return StatisticsStop(station: stopover.station, role: role, platform: platform?.planned)
        }
        var stops: [StatisticsStop] = []
        if let index = boardingIndex { stops.append(stop(trip.stopovers[index], .departure)) }
        if let index = exitIndex { stops.append(stop(trip.stopovers[index], .arrival)) }
        if stops.isEmpty, let highlight, let index = trip.stopovers.firstIndex(where: { $0.station.isSamePlace(as: highlight) }) {
            stops.append(stop(trip.stopovers[index], index == 0 ? .departure : .arrival))
        }
        if stops.isEmpty, let first = trip.stopovers.first, let last = trip.stopovers.last {
            stops = [stop(first, .departure), stop(last, .arrival)]
        }
        return stops
    }

    var body: some View {
        VStack(spacing: 16) {
            if isTicket {
                ticketHeader
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            trainIcon
                            VStack(alignment: .leading, spacing: 3) {
                                trainName
                                if let origin = trip.origin, let destination = trip.destination {
                                    Text("\(origin.displayName) → \(destination.displayName)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fullTextPopup("\(origin.displayName) → \(destination.displayName)", lines: 2)
                                }
                                trainDetails
                            }
                            Spacer()
                            headerButtons
                        }
                        headerExtras
                    }
                }
            }

            if interactive, exitOnly || showsStopTip || picksBoarding || boardingID != nil {
                HStack(spacing: 8) {
                    if exitOnly || showsStopTip || picksBoarding {
                        Image(systemName: "hand.tap.fill").foregroundStyle(Color.brand)
                        Text(exitOnly ? "Tippe auf einen Halt, um dort auszusteigen."
                             : picksBoarding ? "Tippe auf den Halt, an dem du einsteigst."
                             : "Tippe auf Halte, um Ein- und Ausstieg zu wählen.")
                    }
                    Spacer()
                    if !exitOnly, boardingID != nil || exitID != nil {
                        Button("Zurücksetzen", systemImage: "xmark.circle.fill") {
                            withAnimation(.snappy) {
                                boardingID = nil
                                exitID = nil
                            }
                        }
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brand)
                        .accessibilityHint("Hebt Ein- und Ausstieg auf")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }

            Card {
                VStack(spacing: 0) {
                    if trip.hasPreviousLap, let onLoadPreviousLap {
                        lapButton("Vorherige Runde laden", systemImage: "arrow.up.circle", action: onLoadPreviousLap)
                    }
                    ForEach(Array(trip.stopovers.enumerated()), id: \.element.id) { index, stop in
                        // Scroll target, so a sheet can open the list at the exit (#225).
                        stopNode(stop, index: index).id(stop.id)
                    }
                    if trip.hasNextLap, let onLoadNextLap {
                        lapButton("Nächste Runde laden", systemImage: "arrow.down.circle", action: onLoadNextLap)
                    }
                }
            }

            ForEach(trip.remarks, id: \.self) { RemarkRow(text: $0) }
        }
        .task(id: trip.stopovers.map(\.id)) {
            guard let bahnDe = model.provider.bahnDe, let found = try? await bahnDe.operatorStops(for: trip) else { return }
            operatorStops = found
        }
        .task(id: [trip.id, boardingID ?? "", exitID ?? ""]) {
            let boarding = trip.stopovers.first { $0.id == boardingID }, exit = trip.stopovers.first { $0.id == exitID }
            // Over once the ride (or the train) has arrived.
            guard ((exit ?? trip.stopovers.last)?.arrival?.best).map({ $0 > .now }) ?? true, let bahnDe = model.provider.bahnDe else {
                occupancy = nil
                return
            }
            occupancy = try? await bahnDe.occupancy(for: trip, boarding: boarding, exit: exit)
        }
        .onAppear {
            platformStatistics.showCached(line: trip.line, stops: platformHintStops, date: statisticsDate)
            statistics.showCached(line: trip.line, stops: statisticsStops, date: statisticsDate)
        }
        .task(id: [trip.stopovers.first?.id ?? "", String(nextStopIndex ?? -1)]) {
            await platformStatistics.load(line: trip.line, stops: platformHintStops, date: statisticsDate, bahnDe: model.provider.bahnDe)
        }
        .task(id: [boardingID ?? "", exitID ?? "", trip.stopovers.first?.id ?? ""]) {
            await statistics.load(line: trip.line, stops: statisticsStops, date: statisticsDate, bahnDe: model.provider.bahnDe)
        }
        .task(id: [exitID ?? "", trip.stopovers.compactMap { $0.arrivalPlatform?.best }.joined(separator: "|")]) {
            guard let index = exitIndex else { exitSide = nil; return }
            let trip = trip
            exitSide = await Task.detached(priority: .userInitiated) { ExitSides.side(leaving: trip, at: index) }.value
        }
    }

    // MARK: Header

    private var trainIcon: some View {
        LiveTrainIconTile(route: LiveTrainRoute(trip: trip), systemImage: trip.line?.symbolName ?? "tram.fill",
                          color: color, size: 46, logo: trip.line?.transitLogo)
    }

    private var trainName: some View {
        TrainNameRow(name: trip.line?.nameWithTripNumber ?? String(localized: "Zug"), font: .title3.weight(.bold), spacing: 8) {
            TrainSeriesTag(trip: trip, savedLeg: savedLeg)
        }
    }

    /// The railways and the trainsets.
    @ViewBuilder
    private var trainDetails: some View {
        if trip.line?.operatorName != nil {
            TrainOperatorsLabel(source: .trip(trip)).font(.caption).foregroundStyle(.tertiary)
        }
        TrainFormationLabel(trip: trip, savedLeg: savedLeg)
    }

    private var headerButtons: some View {
        HStack(spacing: 8) {
            OccupancyButton(forecast: occupancy, travelClass: model.settings.travelClass)
            TrainMessagesButton(messages: trip.messages)
        }
    }

    /// The Wagenreihung at the next stop (any other stop's unfolds below it with a tap on its platform) and
    /// what past runs say.
    @ViewBuilder
    private var headerExtras: some View {
        CoachSequenceDisclosure(trip: trip, spacing: 14)
        if let rows = statistics.rows {
            TrainStatisticsDisclosure(content: rows).padding(.top, 14)
        }
    }

    /// Fahrkarte: the train on top, "Von" and "Nach" in large type below the perforation.
    private var ticketHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                trainIcon
                VStack(alignment: .leading, spacing: 3) {
                    trainName
                    trainDetails
                }
                Spacer()
                headerButtons
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, trip.origin != nil && trip.destination != nil ? 16 : 0)
            if let origin = trip.origin, let destination = trip.destination {
                TicketPerforation()
                HStack(alignment: .top, spacing: 12) {
                    ticketEnd(String(localized: "Von"), origin.displayName, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 20)
                        .accessibilityHidden(true)
                    ticketEnd(String(localized: "Nach"), destination.displayName, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            VStack(alignment: .leading, spacing: 0) {
                headerExtras
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .fontDesign(.rounded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ticketBackground()
        .environment(\.cardSurface, Color.ticket)
    }

    /// One end of the run on the ticket: a small upper-case label over the station.
    private func ticketEnd(_ label: String, _ name: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .lineLimit(2)
                .fullTextPopup(name, lines: 2)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .accessibilityElement(children: .combine)
    }

    /// Loads the lap before / after the one shown, at the top / bottom of the stops.
    private func lapButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoadingLap { ProgressView().controlSize(.small) } else { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingLap)
    }

    private var boardingIndex: Int? { trip.stopovers.firstIndex { $0.id == boardingID } }
    private var exitIndex: Int? { trip.stopovers.firstIndex { $0.id == exitID } }
    /// Only the exit is known (opened from the arrivals board), so the next tap picks where you got on.
    private var picksBoarding: Bool { !exitOnly && boardingID == nil && exitID != nil }

    private func isRidden(_ index: Int) -> Bool {
        guard let b = boardingIndex else { return false }
        return index >= b && index <= (exitIndex ?? b)
    }

    private func stopNode(_ stop: Stopover, index: Int) -> some View {
        let isBoarding = stop.id == boardingID
        let isExit = stop.id == exitID
        let isMajor = isBoarding || isExit || index == 0 || index == trip.stopovers.count - 1
        let segmentAbove = index > 0 ? (isRidden(index) && isRidden(index - 1) ? color : color.opacity(0.25)) : nil
        let segmentBelow = index < trip.stopovers.count - 1 ? (isRidden(index) && isRidden(index + 1) ? color : color.opacity(0.25)) : nil
        let dimmed = boardingIndex != nil && !isRidden(index) && !isExit

        return TimelineNode(kind: isMajor ? .major : .minor, color: isRidden(index) ? color : color.opacity(0.45),
                             lineAbove: segmentAbove, lineBelow: segmentBelow, dimmed: dimmed) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        withAnimation(.snappy) { showPlannedTimes.toggle() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if let arrival = stop.arrival {
                                DelayTimeText(time: arrival, cancelled: stop.arrivalCancelled, showPlanned: showPlannedTimes,
                                              font: isMajor ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                            }
                            if let departure = stop.departure {
                                DelayTimeText(time: departure, cancelled: stop.departureCancelled, showPlanned: showPlannedTimes,
                                              font: isMajor ? .headline : .subheadline)
                            }
                        }
                        .fontDesign(rounded)
                        .fixedSize()
                        .frame(minWidth: 68, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    Button {
                        guard interactive else { return }
                        select(index)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stop.station.displayName)
                                    .font(isMajor ? .headline : .subheadline)
                                    .fontWeight(highlight.map { stop.station.isSamePlace(as: $0) } == true ? .bold : nil)
                                    .fontDesign(rounded)
                                    .lineLimit(2)
                                if isBoarding {
                                    InfoChip(text: String(localized: "Einstieg"), systemImage: "arrow.up.right.circle.fill", tint: .punctual)
                                } else if isExit {
                                    InfoChip(text: String(localized: "Ausstieg"), systemImage: "arrow.down.right.circle.fill", tint: .brand)
                                }
                                if stop.isAdditional {
                                    InfoChip(text: String(localized: "Zusatzhalt"), systemImage: "plus.circle.fill", tint: .brand)
                                }
                                if stop.isManual {
                                    InfoChip(text: String(localized: "Selbst eingetragen"), systemImage: "hand.point.up.left.fill", tint: .brand)
                                }
                                if let operators = operatorStops[stop.id] {
                                    HStack(spacing: 6) {
                                        ForEach(operators, id: \.self) { OperatorLogo(name: $0) }
                                    }
                                }
                                if let hint = platformChangeHint(at: stop, index: index) {
                                    PlatformChangeLabel(hint: hint)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!interactive)

                    VStack(spacing: 2) {
                        platformButton(stop)
                        if isExit, let exitSide {
                            ExitSideArrow(side: exitSide)
                        }
                    }
                }
                if sequenceStopID == stop.id, let request = coachSequenceRequest(at: stop) {
                    CoachSequencePanel(request: request, run: ExitSides.Run(trip: trip))
                        .transition(.fold)
                }
            }
        }
    }

    /// The stop's platform; tapping it unfolds the Wagenreihung at that stop below it when bahn.de can have one.
    @ViewBuilder
    private func platformButton(_ stop: Stopover) -> some View {
        let platform = stop.departurePlatform?.best != nil ? stop.departurePlatform : stop.arrivalPlatform
        let badge = PlatformBadge(platform: platform)
        if platform?.source == .czechTimetable {
            // Its tap tells where the platform comes from; that note offers the Wagenreihung.
            let request = coachSequenceRequest(at: stop)
            PlatformBadge(platform: platform, onCoachSequence: request.map { _ in { toggleSequence(at: stop) } })
        } else if coachSequenceRequest(at: stop) != nil {
            Button {
                toggleSequence(at: stop)
            } label: {
                badge.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(sequenceStopID == stop.id ? "Blendet die Wagenreihung an diesem Halt aus" : "Zeigt die Wagenreihung an diesem Halt")
        } else {
            badge
        }
    }

    private func toggleSequence(at stop: Stopover) {
        withAnimation(.snappy) { sequenceStopID = sequenceStopID == stop.id ? nil : stop.id }
    }

    private func coachSequenceRequest(at stop: Stopover) -> BahnDeClient.FormationRequest? {
        BahnDeClient.formationRequest(for: trip, at: stop)
    }

    private func select(_ index: Int) {
        let stop = trip.stopovers[index]
        withAnimation(.snappy) {
            if !exitOnly, stop.id == exitID {
                // Tapping the exit again takes it back.
                exitID = nil
            } else if !exitOnly, stop.id == boardingID {
                // Tapping the boarding stop again clears the whole selection, so another one can be picked.
                boardingID = nil
                exitID = nil
            } else if let boardingIndex, index > boardingIndex {
                exitID = stop.id
            } else if picksBoarding, let exitIndex, index < exitIndex {
                boardingID = stop.id
            } else if !exitOnly {
                boardingID = stop.id
                exitID = nil
            } else {
                return
            }
        }
        if !exitOnly { pickedTripStop = true }
        onSelectStop?(stop)
    }
}

/// One stop time, showing either the real-time or the scheduled time (`showPlanned`) with the delay
/// as a compact "+n" badge — tap any time in the list to flip all of them between the two.
private struct DelayTimeText: View {
    let time: TimeInfo
    var cancelled = false
    var showPlanned = false
    var font: Font = .subheadline

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text((showPlanned ? time.planned : time.best).timeString)
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .strikethrough(cancelled, color: .heavyDelay)
                .foregroundStyle(cancelled ? .secondary : .primary)
            if cancelled {
                Text("Ausfall")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Color.heavyDelay)
            } else if showPlanned, let delayMinutes = time.delayMinutes {
                // Original/planned time is shown, so the delay isn't reflected above — show it, even +0; without a
                // live time there is no delay to show, not a made-up "0".
                Text(delayMinutes > 0 ? "+\(delayMinutes)" : "\(delayMinutes)")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .fixedSize()
                    .monospacedDigit()
                    .foregroundStyle(delayColor(delayMinutes))
            } else if let delayMinutes = time.delayMinutes, delayMinutes != 0 {
                // Real-time is shown above, already including the delay — flag it without repeating the time.
                Text(delayMinutes > 0 ? "(+\(delayMinutes))" : "(\(delayMinutes))")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(delayColor(delayMinutes))
            }
        }
    }
}

/// Read-only full route of a train, opened by tapping a leg in a journey plan — shows every stop
/// the train makes, not just the portion between the leg's own origin and destination.
struct LegTripSheet: View {
    let leg: Leg

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var trip: Trip?
    @State private var error: Error?
    /// The full run couldn't be loaded, so only the leg's own saved stops show.
    @State private var showsSavedStops = false
    /// The coupled train whose stops are shown instead of this one's (nil: this one).
    @State private var shownTripId: String?
    /// Laps of a looping train (Ringbahn) loaded before / after the leg's own, by "Vorherige / Nächste Runde laden".
    @State private var extraLapsBefore = 0
    @State private var extraLapsAfter = 0
    @State private var isLoadingLap = false

    private var tripId: String? { shownTripId ?? leg.tripId }

    /// Where the loaded laps are remembered (see `LoadedLaps`).
    private var lapsKey: String? {
        leg.tripId.map { LoadedLaps.key(tripId: $0, station: leg.origin, near: leg.departure.planned) }
    }

    private var runs: [Line.CoupledTrain] {
        guard let line = leg.line, let tripId = leg.tripId else { return [] }
        return line.runs(ownDirection: leg.direction, ownTripId: tripId)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !runs.isEmpty {
                    CoupledTrainPicker(trains: runs, selection: Binding(get: { tripId ?? "" }, set: { switchTrain(to: $0) }))
                        .padding(.horizontal)
                }
                if trip == nil, error == nil {
                    TripLoadingView()
                }
                VStack(spacing: 16) {
                    if let error {
                        ErrorBanner(error: error)
                    }
                    if showsSavedStops {
                        InfoChip(text: String(localized: "Der ganze Zuglauf ist nicht mehr abrufbar. Hier siehst du die gespeicherten Halte deiner Fahrt."),
                                 systemImage: "clock.arrow.circlepath", tint: .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let trip {
                        TripContent(trip: trip, highlight: leg.origin,
                                    boardingID: .constant(boardingID(in: trip)), exitID: .constant(exitID(in: trip)),
                                    interactive: false, savedLeg: tripId == leg.tripId ? leg : nil,
                                    onLoadPreviousLap: { loadLap(before: 1) }, onLoadNextLap: { loadLap(after: 1) },
                                    isLoadingLap: isLoadingLap)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .background { AppBackground() }
            .navigationTitle(leg.line?.displayName ?? String(localized: "Zug"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .onDisappear { if let lapsKey { model.closeLoadedLaps(lapsKey) } }
            .task(id: tripId) {
                if tripId == leg.tripId, let lapsKey, let own = leg.tripId {
                    let remembered = model.openLoadedLaps(lapsKey, tripId: own)
                    extraLapsBefore = remembered.before
                    extraLapsAfter = remembered.after
                }
                if trip == nil, let tripId, let seen = model.liveTrips.value(for: tripId) { trip = seen }
                await load()
                guard let tripId else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: AppModel.realtimeRefreshInterval)
                    guard !Task.isCancelled else { return }
                    if model.isTripSaved(tripId) { await load() }
                }
            }
        }
    }

    /// Where the leg starts: the visit at its planned time, for a looping train that calls here every lap.
    private func boardingID(in trip: Trip) -> String? {
        let visits = trip.stopovers.filter { $0.station.isSamePlace(as: leg.origin) }
        return (visits.first { $0.departure?.planned == leg.departure.planned } ?? visits.first)?.id
    }

    private func exitID(in trip: Trip) -> String? {
        let visits = trip.stopovers.filter { $0.station.isSamePlace(as: leg.destination) }
        return (visits.last { $0.arrival?.planned == leg.arrival.planned } ?? visits.last)?.id
    }

    /// Adds the lap before / after the ones shown and loads the trip again with it.
    private func loadLap(before: Int = 0, after: Int = 0) {
        guard !isLoadingLap else { return }
        extraLapsBefore += before
        extraLapsAfter += after
        if let lapsKey, let own = leg.tripId {
            model.rememberLoadedLaps(.init(before: extraLapsBefore, after: extraLapsAfter), for: lapsKey, tripId: own)
        }
        isLoadingLap = true
        Task {
            await load()
            isLoadingLap = false
        }
    }

    /// Shows the stops of another of the coupled trains.
    private func switchTrain(to id: String) {
        guard id != tripId else { return }
        error = nil
        showsSavedStops = false
        extraLapsBefore = 0
        extraLapsAfter = 0
        shownTripId = id == leg.tripId ? nil : id
        trip = model.liveTrips.value(for: id)
    }

    private func load() async {
        guard let tripId else {
            error = TransitError.notFound(String(localized: "Fahrt"))
            return
        }
        do {
            // The leg's own run is looked up again if a feed import renumbered it (a saved journey's).
            var loaded = tripId == leg.tripId
                ? try await model.provider.trip(for: leg, extraLapsBefore: extraLapsBefore, extraLapsAfter: extraLapsAfter)
                : try await model.provider.plainTrip(id: tripId, source: leg.source)
            guard tripId == self.tripId else { return }
            // The leg's own line knows the trains coupled to it, so the trainsets of both show.
            if tripId == leg.tripId {
                loaded.line = leg.line ?? loaded.line
            } else if let train = runs.first(where: { $0.tripId == tripId }) {
                loaded.line = leg.line?.riding(train, ownDirection: leg.direction, ownTripId: leg.tripId) ?? loaded.line
            }
            error = nil
            showsSavedStops = false
            // Every source's live data in one go (`LiveRun`), like `TripView.load()`. The leg's own train also
            // starts from what the saved journey remembers: its Zusatzhalte (bahn.de only reports them while the
            // train runs) and the delays and platforms last seen, where nothing answers any more.
            var baseline = trip ?? model.liveTrips.value(for: tripId)
            if tripId == leg.tripId, let saved = leg.savedTrip {
                baseline = baseline.map { LiveRun.keepingKnown(from: saved, in: $0) } ?? saved
            }
            let live = await model.liveRun.refresh(loaded, baseline: baseline, wholeRun: true) { partial in
                // Switched to another train meanwhile.
                guard tripId == self.tripId else { return }
                trip = partial
            }
            guard tripId == self.tripId else { return }
            trip = live
            model.rememberLive(live)
        } catch is CancellationError {
        } catch {
            // The leg's own train, gone from Transitous (long past) or not reachable: its saved stops
            // rather than an error. Seen live before, that version stays.
            if tripId == leg.tripId, let saved = leg.savedTrip {
                if trip == nil { trip = saved }
                showsSavedStops = trip == saved
            } else {
                self.error = error
            }
        }
    }
}

#Preview("Fahrtverlauf") {
    @Previewable @State var boarding: String? = PreviewData.trip.stopovers[1].id
    @Previewable @State var exit: String? = PreviewData.trip.stopovers[5].id
    ScrollView {
        TripContent(trip: PreviewData.trip, highlight: PreviewData.duesseldorf, boardingID: $boarding, exitID: $exit)
            .padding()
    }
    .background { AppBackground() }
    .environment(AppModel())
}
