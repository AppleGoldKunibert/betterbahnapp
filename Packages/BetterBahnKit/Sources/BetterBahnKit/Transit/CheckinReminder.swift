import Foundation

/// A reminder to check in on Träwelling, shortly after a train of a saved journey has left (#519).
public struct CheckinReminder: Sendable, Hashable, Identifiable {
    /// The leg to check in on.
    public var legID: String
    /// The last known (live) departure plus `CheckinReminder.delay`.
    public var fireDate: Date
    public var title: String
    public var body: String

    /// One reminder per train: moving it (a new delay) replaces it instead of adding another one.
    public var id: String { "checkin|\(legID)" }

    /// How long after departing the reminder comes.
    public static let delay: TimeInterval = 5 * 60
}

public extension Journey {
    /// The check-in reminders still to come: one for each train that isn't checked in yet, 5 minutes after it
    /// departs. A train that is cancelled, already checked in, or whose reminder time has passed gets none.
    /// - Parameter checkedIn: IDs of the legs the user has checked in on.
    func checkinReminders(now: Date = .now, checkedIn: Set<String> = []) -> [CheckinReminder] {
        transitLegs.compactMap { leg in
            guard !leg.cancelled, !checkedIn.contains(leg.id) else { return nil }
            let fireDate = leg.departure.best.addingTimeInterval(CheckinReminder.delay)
            guard fireDate > now else { return nil }
            return CheckinReminder(legID: leg.id, fireDate: fireDate,
                                   title: String(kit: "Schon eingecheckt?"),
                                   body: String(kit: "Check dich jetzt in %@ nach %@ ein.", leg.line?.name ?? String(kit: "deinen Zug"), leg.destination.displayName))
        }
    }
}
