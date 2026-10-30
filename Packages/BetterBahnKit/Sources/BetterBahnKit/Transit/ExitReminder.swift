import Foundation

/// How long before arriving at a stop where the user gets off (a transfer or the destination) the
/// exit reminder comes (#313).
public enum ExitReminderLead: Int, Codable, Sendable, CaseIterable, Hashable {
    case three = 3
    case five = 5
    case ten = 10

    public var interval: TimeInterval { TimeInterval(rawValue * 60) }
    public var displayName: String { String(kit: "%lld Min. vorher", rawValue) }
}

/// A reminder shortly before a train of a saved journey reaches the stop where the user gets off:
/// "In 5 Min. (+23) Ankunft in Fulda, Ausstieg links – Umstieg in ICE 578 (+23), in 26 Min. auf Gl. 4 statt Gl. 5
/// (Anschluss wartet)" (the side when `ExitSides` knows it).
public struct ExitReminder: Sendable, Hashable, Identifiable {
    /// The leg arriving at the stop.
    public var legID: String
    public var station: String
    /// The last known (live) arrival.
    public var arrival: Date
    /// The arrival minus the lead time, or `now` when that has already passed. Never later than the
    /// last known arrival allows: a delay that grows while the app can't refresh makes it early, not late.
    public var fireDate: Date
    public var title: String
    /// Everything after "In 5 Min.", which depends on when the reminder shows.
    public var details: String

    /// One reminder per stop: moving it (a new delay) replaces it instead of adding another one.
    public var id: String { "exit|\(legID)" }

    /// The text, for a reminder showing at `date` (the fire date, or earlier for the Live Activity).
    public func body(at date: Date) -> String {
        let minutes = Int((arrival.timeIntervalSince(date) / 60).rounded())
        return minutes >= 1 ? String(kit: "In %lld Min. %@", minutes, details) : String(kit: "Gleich %@", details)
    }

    public var body: String { body(at: fireDate) }
}

public extension Journey {
    /// The exit reminders still to come, one for each transit leg's arrival (transfers and the destination).
    /// - Parameters:
    ///   - scheduled: fire dates of the reminders scheduled before, by `ExitReminder.id`. One whose date has
    ///     passed was shown already and doesn't come again, even if a new delay moved the arrival.
    ///   - dispositions: what DB decided for the train departing after a transfer, by that leg's `id`.
    ///   - exitSide: which side of the train the platform is on where the leg ends (#394), if known.
    func exitReminders(lead: TimeInterval, now: Date = .now, scheduled: [String: Date] = [:],
                       dispositions: [String: TransferDisposition] = [:],
                       exitSide: (Leg) -> ExitSide? = { ExitSides.side(leaving: $0) }) -> [ExitReminder] {
        let transit = transitLegs
        var reminders: [ExitReminder] = []
        for (index, leg) in transit.enumerated() where !leg.cancelled {
            let arrival = leg.arrival.best
            guard arrival > now else { continue }
            let id = "exit|\(leg.id)"
            if let shown = scheduled[id], shown <= now { continue }
            let station = leg.destination.displayName
            // "Fulda, Ausstieg links"
            let place = station + (exitSide(leg).map { ", \($0.shortName)" } ?? "")
            var details = Self.delay(leg.arrival).map { "(\($0)) " } ?? ""
            if index + 1 < transit.count {
                let next = transit[index + 1]
                details += String(kit: "Ankunft in %@ – %@", place, Self.transfer(from: leg, to: next, disposition: dispositions[next.id]))
            } else if leg.destination.isSamePlace(as: legs.last?.destination ?? leg.destination) {
                details += String(kit: "Ankunft am Ziel %@", place)
            } else {
                details += String(kit: "Ankunft in %@ – hier aussteigen", place)
            }
            reminders.append(ExitReminder(legID: leg.id, station: station, arrival: arrival,
                                          fireDate: max(arrival.addingTimeInterval(-lead), now),
                                          title: String(kit: "Gleich aussteigen: %@", station), details: details))
        }
        return reminders
    }

    /// "Umstieg in ICE 578 (+23), in 26 Min. auf Gl. 4 statt Gl. 5 (Anschluss wartet)"
    private static func transfer(from leg: Leg, to next: Leg, disposition: TransferDisposition?) -> String {
        var text = String(kit: "Umstieg in %@", next.line?.name ?? String(kit: "Anschlusszug"))
        if let delay = delay(next.departure) { text += " (\(delay))" }
        if !next.origin.isSamePlace(as: leg.destination) { text = String(kit: "%@ ab %@", text, next.origin.displayName) }
        let minutes = Int((next.departure.best.timeIntervalSince(leg.arrival.best) / 60).rounded(.down))
        if minutes < 0, disposition != .waiting {
            text += String(kit: ", fährt vor der Ankunft ab")
        } else {
            text += String(kit: ", in %lld Min.", max(minutes, 0))
            if let platform = next.departurePlatform, let best = platform.best {
                text += String(kit: " auf Gl. %@", best)
                if let planned = platform.planned, PlatformInfo.isDifferentTrack(planned, best) { text += String(kit: " statt Gl. %@", planned) }
            }
        }
        if let disposition { text += " (\(disposition.title))" }
        return text
    }

    /// "+23" for a delay, nil when on time (or early).
    private static func delay(_ time: TimeInfo) -> String? {
        guard let minutes = time.delayMinutes, minutes > 0 else { return nil }
        return "+\(minutes)"
    }
}
