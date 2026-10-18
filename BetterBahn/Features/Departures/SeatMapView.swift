import BetterBahnKit
import SwiftUI

/// The train from above with every seat (#365), opened by tapping a coach in the Wagenreihung: the
/// coaches DB has seat maps for, left to right as on the platform, scrolled to the tapped one (or the
/// reserved seat in it). Coaches standing the other way round are turned, their seat numbers stay
/// upright. Drawings: DB's Wagenreihungspläne, © Deutsche Bahn AG.
struct SeatMapSheet: View {
    let sequence: CoachSequence
    /// The coaches from left to right, as the platform diagram shows them.
    let coaches: [CoachSequence.Coach]
    let selected: CoachSequence.Coach
    var reservation: SeatReservation?

    @Environment(\.dismiss) private var dismiss

    private static let coachHeight: CGFloat = 180

    private struct Item: Identifiable {
        var coach: CoachSequence.Coach
        var map: SeatMap
        var turned: Bool
        var id: Int { coach.id }
    }

    private var items: [Item] {
        coaches.compactMap { coach in
            guard let map = sequence.seatMap(for: coach) else { return nil }
            let numbers = coaches.filter { $0.group == coach.group }.compactMap(\.number)
            return Item(coach: coach, map: map, turned: SeatMap.isTurned(numbersLeftToRight: numbers))
        }
    }

    private func reservedSeats(in coach: CoachSequence.Coach) -> Set<String> {
        guard let reservation, reservation.coach == coach.number else { return [] }
        return Set(reservation.seats)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if let reservation, !reservation.description.isEmpty {
                        Label(reservation.description, systemImage: "person.crop.square.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brand)
                            .padding(.horizontal, 16)
                    }
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(items) { item in
                                    coachColumn(item)
                                        .id(item.id)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .onAppear { scroll(proxy) }
                    }
                    if let towardsEnd = sequence.travelsTowardsPlatformEnd {
                        HStack(spacing: 4) {
                            if !towardsEnd { Image(systemName: "arrow.left") }
                            Text("Fahrtrichtung")
                            if towardsEnd { Image(systemName: "arrow.right") }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: towardsEnd ? .trailing : .leading)
                        .padding(.horizontal, 16)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(towardsEnd ? "Fahrtrichtung nach rechts" : "Fahrtrichtung nach links")
                    }
                    Text("Quelle: Deutsche Bahn")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Sitzplan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// To the reserved seat in the tapped coach, else to the coach's start.
    private func scroll(_ proxy: ScrollViewProxy) {
        if let seat = reservedSeats(in: selected).sorted().first {
            proxy.scrollTo(SeatMapCoach.seatID(coach: selected.id, seat: seat), anchor: .center)
        } else {
            proxy.scrollTo(selected.id, anchor: .leading)
        }
    }

    private func coachColumn(_ item: Item) -> some View {
        let reserved = reservedSeats(in: item.coach)
        let title = [item.coach.number.map { "Wagen \($0)" }, item.coach.title == "Wagen" ? nil : item.coach.title]
            .compactMap(\.self).joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.id == selected.id ? Color.brand : .primary)
            SeatMapCoach(map: item.map, turned: item.turned, reserved: reserved, height: Self.coachHeight, coachID: item.id)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(reserved.isEmpty ? "" : "Dein Platz " + reserved.sorted().joined(separator: ", "))
    }
}

/// One coach's drawing with its seat numbers drawn on top, reserved seats highlighted.
private struct SeatMapCoach: View {
    let map: SeatMap
    let turned: Bool
    let reserved: Set<String>
    let height: CGFloat
    let coachID: Int

    static func seatID(coach: Int, seat: String) -> String { "\(coach)-\(seat)" }

    var body: some View {
        let width = height * map.aspectRatio
        Image(map.imageName)
            .resizable()
            .frame(width: width, height: height)
            .rotationEffect(turned ? .degrees(180) : .zero)
            .overlay {
                // Turned round, the pictograms would stand on their heads: each is drawn again from the
                // unturned drawing at its turned place.
                if turned {
                    ForEach(Array(map.icons.enumerated()), id: \.offset) { _, icon in
                        Image(map.imageName)
                            .resizable()
                            .frame(width: width, height: height)
                            .offset(x: -icon.x * width, y: -icon.y * height)
                            .frame(width: icon.width * width, height: icon.height * height, alignment: .topLeading)
                            .clipped()
                            .position(x: (1 - icon.x - icon.width / 2) * width, y: (1 - icon.y - icon.height / 2) * height)
                    }
                }
            }
            .overlay {
                ForEach(Array(map.seats.enumerated()), id: \.offset) { _, seat in
                    // Turned round, a seat's box moves to the opposite corner; its number stays upright.
                    let x = turned ? 1 - seat.x - seat.width : seat.x
                    let y = turned ? 1 - seat.y - seat.height : seat.y
                    let isReserved = reserved.contains(seat.number)
                    let size = seat.height * height
                    Text(seat.number)
                        .font(.system(size: size * 0.8, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(isReserved ? size * 0.35 : 0)
                        .background {
                            if isReserved {
                                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                                    .fill(Color.brand)
                                    .stroke(.white, lineWidth: 1.5)
                                    .shadow(radius: 2)
                            }
                        }
                        .position(x: (x + seat.width / 2) * width, y: (y + seat.height / 2) * height)
                        .id(Self.seatID(coach: coachID, seat: seat.number))
                }
            }
            .frame(width: width, height: height)
    }
}
