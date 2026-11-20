import BetterBahnKit
import SwiftUI

/// The train from above with every seat (#365), opened by tapping a coach in the Wagenreihung: the
/// coaches DB has seat maps for, left to right as on the platform, scrolled to the tapped one (or the
/// reserved seat in it). Coaches standing the other way round are turned, their seat numbers stay
/// upright. With the ride (`leg`), the seats still free on it in the settings' class are green, with a
/// count per coach (bahn.de's seat picker). Drawings: DB's Wagenreihungspläne, © Deutsche Bahn AG.
struct SeatMapSheet: View {
    let sequence: CoachSequence
    /// The coaches from left to right, as the platform diagram shows them.
    let coaches: [CoachSequence.Coach]
    let selected: CoachSequence.Coach
    var reservation: SeatReservation?
    /// The ride whose free seats are shown.
    var leg: Leg?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design
    @Environment(AppModel.self) private var model
    @State private var availability: SeatAvailability?
    /// The class `availability` is for.
    @State private var travelClass: TravelClass = .second

    /// Fahrkarte: the seat and the coaches' names in the rounded type (#504).
    private var rounded: Font.Design? { design == .fahrkarte ? .rounded : nil }

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

    /// Whether the coach has seats of the class the free seats are for; the other class's never are.
    private func servesClass(_ coach: CoachSequence.Coach) -> Bool {
        travelClass == .first ? coach.firstClass : coach.secondClass
    }

    /// The free seats in `coach`, nil when bahn.de said nothing about it (another class, a coupled train).
    private func freeSeats(in coach: CoachSequence.Coach) -> Set<String>? {
        guard let availability, servesClass(coach), availability.knows(coach: coach.number) else { return nil }
        return availability.freeSeats(in: coach.number)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if let reservation, !reservation.description.isEmpty {
                        Label(reservation.description, systemImage: "person.crop.square.fill")
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(rounded)
                            .foregroundStyle(Color.brandText)
                            .padding(.horizontal, 16)
                    }
                    if let availability {
                        freeSeatsNote(availability)
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
        .task {
            guard let leg else { return }
            travelClass = model.settings.travelClass
            availability = await model.seatAvailability(for: leg)
        }
    }

    /// What the green seats mean, or that nothing is left.
    private func freeSeatsNote(_ availability: SeatAvailability) -> some View {
        let full = availability.bookedOut || availability.freeCount == 0
        return Label(full ? String(localized: "In der \(travelClass.displayName) ist auf deiner Strecke kein Platz mehr frei.")
                          : String(localized: "Grüne Plätze sind auf deiner Strecke in der \(travelClass.displayName) noch frei."),
                     systemImage: full ? "person.2.slash" : "checkmark.seal")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        let free = freeSeats(in: item.coach)
        let title = [item.coach.number.map { String(localized: "Wagen \($0)") }, item.coach.hasKindOrClass ? item.coach.title : nil,
                     free.map { String(localized: "\($0.count) frei") }]
            .compactMap(\.self).joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontDesign(rounded)
                .foregroundStyle(item.id == selected.id ? Color.brandText : .primary)
            SeatMapCoach(map: item.map, turned: item.turned, reserved: reserved, free: free ?? [], height: Self.coachHeight, coachID: item.id)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(reserved.isEmpty ? "" : String(localized: "Dein Platz \(reserved.sorted().joined(separator: ", "))"))
    }
}

/// One coach's drawing with its seat numbers drawn on top, reserved seats highlighted, free ones green.
private struct SeatMapCoach: View {
    let map: SeatMap
    let turned: Bool
    let reserved: Set<String>
    let free: Set<String>
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
                    let isFree = !isReserved && free.contains(seat.number)
                    let size = seat.height * height
                    Text(seat.number)
                        .font(.system(size: size * 0.8, weight: .bold))
                        // On the accent-filled box of the reserved seat: black where white wouldn't read.
                        .foregroundStyle(isReserved ? Color.onBrandText : Color.white)
                        .fixedSize()
                        .padding(isReserved ? size * 0.35 : isFree ? size * 0.12 : 0)
                        .background {
                            if isReserved {
                                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                                    .fill(Color.brandText)
                                    .stroke(.white, lineWidth: 1.5)
                                    .shadow(radius: 2)
                            } else if isFree {
                                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                                    .fill(Color.punctual)
                            }
                        }
                        .position(x: (x + seat.width / 2) * width, y: (y + seat.height / 2) * height)
                        .id(Self.seatID(coach: coachID, seat: seat.number))
                }
            }
            .frame(width: width, height: height)
    }
}
