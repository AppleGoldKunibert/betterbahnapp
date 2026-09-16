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
                Text(leg.origin.name).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption.weight(.bold))
                Text(leg.destination.name).lineLimit(1)
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

    private var color: Color { trip.line?.product.color ?? .gray }

    var body: some View {
        VStack(spacing: 16) {
            Card {
                HStack(spacing: 12) {
                    IconTile(systemImage: trip.line?.product.symbolName ?? "tram.fill", color: color, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(trip.line?.name ?? "Zug").font(.title3.weight(.bold))
                        if let origin = trip.origin, let destination = trip.destination {
                            Text("\(origin.name) → \(destination.name)")
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

            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill").foregroundStyle(Color.brand)
                Text("Tippe auf Halte, um Ein- und Ausstieg zu wählen.")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

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
            select(index)
        } label: {
            TimelineNode(kind: isMajor ? .major : .minor, color: isRidden(index) ? color : color.opacity(0.45),
                         lineAbove: segmentAbove, lineBelow: segmentBelow, dimmed: dimmed) {
                HStack(alignment: .top, spacing: 10) {
                    if let time = stop.departure ?? stop.arrival {
                        TimeStack(time: time, cancelled: stop.cancelled, font: isMajor ? .headline : .subheadline)
                            .frame(width: 52, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stop.station.name)
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

#Preview("Fahrtverlauf") {
    @Previewable @State var boarding: String? = PreviewData.trip.stopovers[1].id
    @Previewable @State var exit: String? = PreviewData.trip.stopovers[5].id
    ScrollView {
        TripContent(trip: PreviewData.trip, highlight: PreviewData.duesseldorf, boardingID: $boarding, exitID: $exit)
            .padding()
    }
    .background { AppBackground() }
}
