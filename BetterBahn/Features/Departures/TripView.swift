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

    var body: some View {
        ScrollView {
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
        .overlay {
            if trip == nil, error == nil { ProgressView("Lade Fahrtverlauf …") }
        }
        .safeAreaInset(edge: .bottom) {
            if let leg = selectedLeg {
                actionBar(leg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedLeg?.id)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(entry.line.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var selectedLeg: Leg? {
        guard let trip,
              let boarding = trip.stopovers.first(where: { $0.id == boardingID }),
              let exit = trip.stopovers.first(where: { $0.id == exitID }) else { return nil }
        return trip.leg(from: boarding.station, to: exit.station)
    }

    private func actionBar(_ leg: Leg) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(leg.origin.displayName).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption.weight(.bold))
                Text(leg.destination.displayName).lineLimit(1)
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

    private func load() async {
        do {
            let loaded = try await model.provider.trip(id: entry.tripId, source: entry.source)
            trip = loaded
            if boardingID == nil {
                let here = loaded.stopovers.first { $0.station.isSamePlace(as: entry.station) }?.id
                if entry.kind == .arrivals {
                    // For arrivals the selected station is where you get off.
                    exitID = here
                    boardingID = loaded.stopovers.first?.id
                } else {
                    boardingID = here
                }
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error
        }
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

    private var color: Color { trip.line?.product.color ?? .gray }

    var body: some View {
        VStack(spacing: 16) {
            Card {
                HStack(spacing: 12) {
                    IconTile(systemImage: trip.line?.product.symbolName ?? "tram.fill", color: color, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(trip.line?.name ?? "Zug").font(.title3.weight(.bold))
                        if let origin = trip.origin, let destination = trip.destination {
                            Text("\(origin.displayName) → \(destination.displayName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let op = trip.line?.operatorName {
                            Label(op, systemImage: "building.2.fill").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
            }

            if interactive {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill").foregroundStyle(Color.brand)
                    Text("Tippe auf Halte, um Ein- und Ausstieg zu wählen.")
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

        return Button {
            guard interactive else { return }
            select(index)
        } label: {
            TimelineNode(kind: isMajor ? .major : .minor, color: isRidden(index) ? color : color.opacity(0.45),
                         lineAbove: segmentAbove, lineBelow: segmentBelow, dimmed: dimmed) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let arrival = stop.arrival, stop.departure != nil {
                            Text(arrival.best.timeString)
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .strikethrough(stop.cancelled, color: .heavyDelay)
                                .foregroundStyle(.secondary)
                        }
                        if let time = stop.departure ?? stop.arrival {
                            TimeStack(time: time, cancelled: stop.cancelled, font: isMajor ? .headline : .subheadline)
                        }
                    }
                    .frame(width: 52, alignment: .leading)
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
                    }
                    Spacer()
                    PlatformBadge(platform: stop.departurePlatform?.best != nil ? stop.departurePlatform : stop.arrivalPlatform)
                }
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
    }

    private func select(_ index: Int) {
        let stop = trip.stopovers[index]
        withAnimation(.snappy) {
            if let boardingIndex, index > boardingIndex {
                exitID = stop.id
            } else {
                boardingID = stop.id
                exitID = nil
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

    var body: some View {
        NavigationStack {
            ScrollView {
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
            .overlay {
                if trip == nil, error == nil { ProgressView("Lade Fahrtverlauf …") }
            }
            .navigationTitle(leg.line?.name ?? "Zug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func boardingID(in trip: Trip) -> String? {
        trip.stopovers.first { $0.station.isSamePlace(as: leg.origin) }?.id
    }

    private func exitID(in trip: Trip) -> String? {
        trip.stopovers.last { $0.station.isSamePlace(as: leg.destination) }?.id
    }

    private func load() async {
        guard let tripId = leg.tripId else {
            error = TransitError.notFound("Fahrt")
            return
        }
        do {
            trip = try await model.provider.trip(id: tripId, source: leg.source)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error
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
