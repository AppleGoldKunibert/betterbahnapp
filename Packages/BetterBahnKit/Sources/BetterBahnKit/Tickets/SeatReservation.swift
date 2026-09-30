import Foundation

/// A reserved seat on one train of a journey ("Wagen 2, Platz 37, 38"), as printed on its ticket.
public struct SeatReservation: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    /// The train as named on the booking, e.g. "EUROSTAR 9149" or "ICE 652".
    public var trainName: String
    public var coach: String
    public var seats: [String]

    public init(trainName: String, coach: String, seats: [String]) {
        self.trainName = trainName
        self.coach = coach
        self.seats = seats
    }

    public init(_ seat: DBTicket.Seat) {
        self.init(trainName: seat.train, coach: seat.coach, seats: seat.seats)
    }

    /// "Wagen 2 · Platz 37, 38"
    public var description: String {
        var parts: [String] = []
        if !coach.isEmpty { parts.append("Wagen \(coach)") }
        if !seats.isEmpty { parts.append((seats.count == 1 ? "Platz " : "Plätze ") + seats.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Whether this reservation is for the train `leg` rides. Booking names and feed names differ
    /// ("EUROSTAR 9149" vs. "EST 9149"), so the train number decides when the name doesn't.
    public func matches(_ leg: Leg) -> Bool {
        DBShareImporter.matches(trainName, leg.line)
    }

}
