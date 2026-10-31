import Foundation

/// A seat saved on the train being ridden, without a reservation (#410), e.g. to find it again after a trip to
/// the Bordbistro. Its coach is highlighted like a reserved one, and the coach advice (#383) walks from it.
/// Kept on the device only, until a while after the ride.
public struct SavedSeat: Codable, Sendable, Hashable {
    /// Train, first stop and planned departure: unlike the feed's trip ID they stay the same while riding.
    public var ride: String
    /// "ICE 597", or "RE 3307" for a regional line's run, as reservations name the train.
    public var trainName: String
    public var coach: String
    public var seat: String?
    /// The ride's planned arrival.
    public var arrival: Date

    public init(leg: Leg, coach: String, seat: String? = nil) {
        ride = Self.ride(of: leg)
        trainName = Self.trainName(of: leg)
        self.coach = coach
        let seat = seat?.trimmingCharacters(in: .whitespaces)
        self.seat = seat?.isEmpty == false ? seat : nil
        arrival = leg.arrival.planned
    }

    /// Kept this long past the planned arrival, for late trains.
    static let keptAfterArrival: TimeInterval = 6 * 3600
    /// Offered from this long before the departure, while boarding.
    static let offeredBeforeDeparture: TimeInterval = 15 * 60

    static func ride(of leg: Leg) -> String {
        [leg.line?.name ?? "", leg.origin.id, String(Int(leg.departure.planned.timeIntervalSince1970))].joined(separator: "|")
    }

    static func trainName(of leg: Leg) -> String {
        guard let line = leg.line else { return "" }
        guard let run = line.tripNumber ?? line.number, let kind = line.name.split(separator: " ").first else { return line.name }
        return "\(kind) \(run)"
    }

    public func belongs(to leg: Leg) -> Bool {
        ride == Self.ride(of: leg)
    }

    /// "Wagen 7 · Platz 45"
    public var description: String {
        ([String(kit: "Wagen %@", coach)] + (seat.map { [String(kit: "Platz %@", $0)] } ?? [])).joined(separator: " · ")
    }

    public func isOver(now: Date = .now) -> Bool {
        now > arrival.addingTimeInterval(Self.keptAfterArrival)
    }

    /// Whether to offer saving a seat on `leg`: while boarding and on the way.
    public static func offered(on leg: Leg, now: Date = .now) -> Bool {
        !leg.cancelled && !leg.isWalking
            && leg.departure.best.addingTimeInterval(-offeredBeforeDeparture) <= now && now < leg.arrival.best
    }

    /// `seats` with `seat` saved for `leg` instead of the one before (nil removes it), dropping those of finished rides.
    public static func saving(_ seat: SavedSeat?, for leg: Leg, in seats: [SavedSeat], now: Date = .now) -> [SavedSeat] {
        seats.filter { !$0.belongs(to: leg) && !$0.isOver(now: now) } + (seat.map { [$0] } ?? [])
    }
}

extension CoachSequence {
    /// The numbers of the requested train's coaches with seats, from the lowest, to save a seat in (#410).
    public var seatCoachNumbers: [String] {
        var seen = Set<String>()
        return boardable(travelClass: nil).compactMap(\.number)
            .filter { seen.insert($0).inserted }
            .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
    }
}
