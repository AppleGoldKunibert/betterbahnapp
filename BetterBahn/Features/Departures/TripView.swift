import BetterBahnKit
import SwiftUI

/// Full route of a train from the station board. Pick where you get on/off to check in
/// or start a Live Activity.
struct TripView: View {
    let entry: BoardEntry

    @Environment(AppModel.self) private var model
    @State private var trip: Trip?
    @State private var boardingID: String?
    @State private var exitID: String?
    @State private var error: Error?
    /// The coupled train whose stops are shown instead of this one's (nil: this one).
    @State private var shownTripId: String?
    /// Where you got on/off before switching trains, picked again in the other one.
    @State private var keptStops: (boarding: Station?, exit: Station?)?

    private var tripId: String { shownTripId ?? entry.tripId }

    private var ownDirection: String? { entry.kind == .departures ? entry.otherEnd : nil }

    private var runs: [Line.CoupledTrain] { entry.line.runs(ownDirection: ownDirection, ownTripId: entry.tripId) }

    var body: some View {
        ScrollView {
            if !runs.isEmpty {
                CoupledTrainPicker(trains: runs, selection: Binding(get: { tripId }, set: switchTrain))
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
                    TripContent(trip: trip, highlight: entry.station, boardingID: $boardingID, exitID: $exitID)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
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
        .task(id: tripId) {
            // Seen before: its last live data right away, refreshed below.
            if trip == nil, let seen = model.liveTrips.value(for: tripId) { show(seen) }
            await load()
            await autoRefresh(tripId: tripId)
        }
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
            SaveJourneyButton(journey: Journey(legs: [leg], source: leg.source))
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
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
            var loaded = try await model.provider.trip(id: tripId, source: entry.source)
            if tripId != entry.tripId, let train = runs.first(where: { $0.tripId == tripId }) {
                // A coupled train: it leads, this one becomes the coupled one.
                loaded.line = entry.line.riding(train, ownDirection: ownDirection, ownTripId: entry.tripId)
            } else if let name = loaded.line?.name, entry.line.alternateName == name || entry.line.coupledTrains != nil {
                // The board may have taken bahn.de's name for this train (e.g. "RJ 171" for Transitous'
                // "ICE 171"), or found the trains coupled to it; keep that rather than switching back.
                loaded.line = entry.line
            }
            guard tripId == self.tripId else { return }
            error = nil
            // DB's delays and the platforms Transitous lacks (e.g. for the S15's own first/last stop at
            // Berlin Hbf) before showing a trip not seen before, so it doesn't jump from the timetable to
            // the live times; one already showing (seen before, or a reload) stays meanwhile.
            if let timetables = model.timetablesClient {
                let timetable = loaded
                let live = await LoadingDeadline.run({ await timetables.liveTrip(timetable) }, showingAfter: LoadingDeadline.liveData) {
                    if trip == nil, tripId == self.tripId { show(timetable) }
                }
                // Switched to another train meanwhile.
                guard tripId == self.tripId else { return }
                show(live)
            } else {
                show(loaded)
            }
            await insertZusatzhalte()
            if let trip { model.rememberLive(trip) }
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    private func show(_ loaded: Trip) {
        trip = loaded
        guard boardingID == nil else { return }
        if let keptStops {
            boardingID = keptStops.boarding.flatMap { kept in loaded.stopovers.first { $0.station.isSamePlace(as: kept) }?.id }
            exitID = keptStops.exit.flatMap { kept in loaded.stopovers.last { $0.station.isSamePlace(as: kept) }?.id }
            if boardingID != nil { return }
        }
        let here = loaded.stopovers.first { $0.station.isSamePlace(as: entry.station) }?.id
        if entry.kind == .arrivals {
            // For arrivals the selected station is where you get off.
            exitID = here
            boardingID = loaded.stopovers.first?.id
        } else {
            boardingID = here
        }
    }

    /// Only bahn.de's journey details report a Zusatzhalt (an unscheduled stop the train additionally
    /// picked up today) at all — Transitous and DB Timetables above only ever overlay onto stops already there.
    private func insertZusatzhalte() async {
        guard let trip, let bahnDe = model.provider.bahnDe, let stops = try? await bahnDe.journeyStops(for: trip),
              self.trip?.id == trip.id else { return }
        self.trip?.stopovers = BahnDeClient.inserting(stops, into: trip.stopovers)
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
    let highlight: Station
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
    /// Tapping any stop time flips every stop between real-time and scheduled times — app-wide, and remembered.
    @AppStorage("showPlannedTimes") private var showPlannedTimes = false
    @State private var sequenceRequest: BahnDeClient.FormationRequest?

    private var color: Color { trip.line?.product.color ?? .gray }

    var body: some View {
        VStack(spacing: 16) {
            Card {
                HStack(spacing: 12) {
                    LiveTrainIconTile(route: LiveTrainRoute(trip: trip), systemImage: trip.line?.product.symbolName ?? "tram.fill",
                                      color: color, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        TrainNameRow(name: trip.line?.name ?? "Zug", font: .title3.weight(.bold), spacing: 8) {
                            TrainSeriesTag(trip: trip)
                        }
                        if let origin = trip.origin, let destination = trip.destination {
                            Text("\(origin.displayName) → \(destination.displayName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fullTextPopup("\(origin.displayName) → \(destination.displayName)", lines: 2)
                        }
                        if let op = trip.line?.operatorName {
                            Label(op, systemImage: "building.2.fill").font(.caption).foregroundStyle(.tertiary)
                        }
                        TrainFormationLabel(trip: trip)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        TrainMessagesButton(messages: trip.messages)
                        CoachSequenceButton(trip: trip)
                    }
                }
            }

            if interactive {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill").foregroundStyle(Color.brand)
                    Text(exitOnly ? "Tippe auf einen Halt, um dort auszusteigen."
                                  : "Tippe auf Halte, um Ein- und Ausstieg zu wählen.")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }

            Card {
                VStack(spacing: 0) {
                    ForEach(Array(trip.stopovers.enumerated()), id: \.element.id) { index, stop in
                        stopNode(stop, index: index)
                    }
                }
            }

            ForEach(trip.remarks, id: \.self) { RemarkRow(text: $0) }
        }
        .sheet(isPresented: Binding(get: { sequenceRequest != nil }, set: { if !$0 { sequenceRequest = nil } })) {
            if let sequenceRequest {
                CoachSequenceView(request: sequenceRequest, trainName: trip.line?.name)
            }
        }
    }

    private var boardingIndex: Int? { trip.stopovers.firstIndex { $0.id == boardingID } }
    private var exitIndex: Int? { trip.stopovers.firstIndex { $0.id == exitID } }

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
                                .fontWeight(stop.station.isSamePlace(as: highlight) ? .bold : nil)
                                .lineLimit(2)
                            if isBoarding {
                                InfoChip(text: "Einstieg", systemImage: "arrow.up.right.circle.fill", tint: .punctual)
                            } else if isExit {
                                InfoChip(text: "Ausstieg", systemImage: "arrow.down.right.circle.fill", tint: .brand)
                            }
                            if stop.isAdditional {
                                InfoChip(text: "Zusatzhalt", systemImage: "plus.circle.fill", tint: .brand)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!interactive)

                platformButton(stop)
            }
        }
    }

    /// The stop's platform; tapping it opens the Wagenreihung at that stop when bahn.de can have one.
    @ViewBuilder
    private func platformButton(_ stop: Stopover) -> some View {
        let badge = PlatformBadge(platform: stop.departurePlatform?.best != nil ? stop.departurePlatform : stop.arrivalPlatform)
        if let request = coachSequenceRequest(at: stop) {
            Button {
                sequenceRequest = request
            } label: {
                badge.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Zeigt die Wagenreihung an diesem Halt")
        } else {
            badge
        }
    }

    private func coachSequenceRequest(at stop: Stopover) -> BahnDeClient.FormationRequest? {
        guard let ref = BahnDeClient.sequenceReference(for: trip.line), !stop.cancelled,
              let time = (stop.departure ?? stop.arrival)?.planned,
              (stop.departurePlatform ?? stop.arrivalPlatform)?.best != nil else { return nil }
        return BahnDeClient.FormationRequest(category: ref.category, number: ref.number, station: stop.station, plannedDeparture: time)
    }

    private func select(_ index: Int) {
        let stop = trip.stopovers[index]
        withAnimation(.snappy) {
            if let boardingIndex, index > boardingIndex {
                exitID = stop.id
            } else if !exitOnly {
                boardingID = stop.id
                exitID = nil
            } else {
                return
            }
        }
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
            } else if showPlanned {
                // Original/planned time is shown, so the delay isn't reflected above — always show it, even +0.
                let delayMinutes = time.delayMinutes ?? 0
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
    /// The coupled train whose stops are shown instead of this one's (nil: this one).
    @State private var shownTripId: String?

    private var tripId: String? { shownTripId ?? leg.tripId }

    private var runs: [Line.CoupledTrain] {
        guard let line = leg.line, let tripId = leg.tripId else { return [] }
        return line.runs(ownDirection: leg.direction, ownTripId: tripId)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !runs.isEmpty {
                    CoupledTrainPicker(trains: runs, selection: Binding(get: { tripId ?? "" }, set: switchTrain))
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
                        TripContent(trip: trip, highlight: leg.origin,
                                    boardingID: .constant(boardingID(in: trip)), exitID: .constant(exitID(in: trip)),
                                    interactive: false)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .background { AppBackground() }
            .navigationTitle(leg.line?.displayName ?? "Zug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .task(id: tripId) {
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

    private func boardingID(in trip: Trip) -> String? {
        trip.stopovers.first { $0.station.isSamePlace(as: leg.origin) }?.id
    }

    private func exitID(in trip: Trip) -> String? {
        trip.stopovers.last { $0.station.isSamePlace(as: leg.destination) }?.id
    }

    /// Shows the stops of another of the coupled trains.
    private func switchTrain(to id: String) {
        guard id != tripId else { return }
        error = nil
        shownTripId = id == leg.tripId ? nil : id
        trip = model.liveTrips.value(for: id)
    }

    private func load() async {
        guard let tripId else {
            error = TransitError.notFound("Fahrt")
            return
        }
        do {
            let loaded = try await model.provider.trip(id: tripId, source: leg.source)
            guard tripId == self.tripId else { return }
            error = nil
            // Live data first, like `TripView.load()`.
            if let timetables = model.timetablesClient {
                let live = await LoadingDeadline.run({ await timetables.liveTrip(loaded) }, showingAfter: LoadingDeadline.liveData) {
                    if trip == nil, tripId == self.tripId { trip = loaded }
                }
                // Switched to another train meanwhile.
                guard tripId == self.tripId else { return }
                trip = live
            } else {
                trip = loaded
            }
            await insertZusatzhalte()
            if let trip { model.rememberLive(trip) }
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    /// Only bahn.de's journey details report a Zusatzhalt (an unscheduled stop the train additionally
    /// picked up today) at all — Transitous and DB Timetables above only ever overlay onto stops already there.
    private func insertZusatzhalte() async {
        guard let trip, let bahnDe = model.provider.bahnDe, let stops = try? await bahnDe.journeyStops(for: trip),
              self.trip?.id == trip.id else { return }
        self.trip?.stopovers = BahnDeClient.inserting(stops, into: trip.stopovers)
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
