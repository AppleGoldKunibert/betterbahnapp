import Foundation

/// What a saved journey's calendar event says (#382): "ICE 597 → München Hbf" from departure to
/// arrival at the departure station, with the platforms, changes and reserved seats in the notes.
/// Built from the latest data, so an event kept current changes with delays and platform changes.
public struct JourneyCalendarEvent: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    /// The departure station; with its coordinate Maps and the travel time alert know where it is.
    public var location: String
    public var coordinate: Coordinate?
    public var notes: String
    public var url: URL?

    /// Nil for a journey without trains. `link` opens the journey in the app.
    public init?(journey: Journey, reservations: [SeatReservation] = [], link: URL? = nil) {
        let trains = journey.transitLegs
        guard let first = trains.first, let origin = journey.legs.first?.origin,
              let destination = journey.legs.last?.destination,
              let start = journey.departure?.best, let end = journey.arrival?.best else { return nil }
        // On long journeys the city says enough: "Köln → München" instead of "Köln Hbf → München Hbf".
        let isLong = origin.coordinate.flatMap { from in destination.coordinate.map { from.distance(to: $0) } }
            .map { $0 >= Self.longJourneyDistance } ?? false
        func name(_ station: Station) -> String {
            let name = station.displayName
            guard isLong, name.hasSuffix(" Hbf") else { return name }
            return String(name.dropLast(4))
        }
        if trains.count == 1, let line = first.line {
            title = "\(line.displayName) → \(name(destination))"
        } else {
            title = "\(name(origin)) → \(name(destination))"
        }
        self.start = start
        self.end = max(end, start)
        location = origin.displayName
        coordinate = origin.coordinate

        func seat(_ leg: Leg) -> String {
            reservations.first { $0.matches(leg) }.map { " · " + $0.description } ?? ""
        }
        var lines = [Self.train(first, from: origin) + seat(first)]
        for (previous, next) in zip(trains, trains.dropFirst()) {
            let minutes = Int(next.departure.best.timeIntervalSince(previous.arrival.best) / 60)
            lines.append("Umstieg in \(previous.destination.displayName) (\(max(minutes, 0)) Min.): "
                         + Self.train(next, from: previous.destination) + seat(next))
        }
        if let link { lines += ["", "In BetterBahn öffnen: \(link.absoluteString)"] }
        notes = lines.joined(separator: "\n")
        url = link
    }

    /// From this straight-line distance (m) main stations are named by their city in the title.
    static let longJourneyDistance: Double = 100_000

    /// "ICE 597 ab Gl. 5", "ICE 123 ab Mannheim ARENA, Gl. 3" when it leaves from another station
    /// than `station`, "… – fällt aus" when cancelled.
    private static func train(_ leg: Leg, from station: Station) -> String {
        var place: [String] = []
        if !leg.origin.isSamePlace(as: station) { place.append(leg.origin.displayName) }
        if let platform = leg.departurePlatform?.best { place.append("Gl. \(platform)") }
        var text = leg.line?.displayName ?? "Zug"
        if !place.isEmpty { text += " ab " + place.joined(separator: ", ") }
        if leg.cancelled { text += " – fällt aus" }
        return text
    }
}

/// What the app may do with a journey's calendar event, chosen by the user (#382). iOS's write-only
/// access can't change an event once it's added.
public enum CalendarAccessMode: String, Codable, Sendable, CaseIterable {
    /// Events follow delays, platform changes and replanning, and go when the journey is deleted.
    case full
    /// Events are added once and left as they are.
    case addOnly

    public var displayName: String {
        switch self {
        case .full: "Voller Zugriff"
        case .addOnly: "Nur hinzufügen"
        }
    }
}
