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

/// Where a check-in reminder's notification points: its identifier is `checkin|<saved journey>|<leg>` (#580).
public extension CheckinReminder {
    static let notificationPrefix = "checkin|"

    static func notificationID(entry: UUID, legID: String) -> String {
        notificationPrefix + entry.uuidString + "|" + legID
    }

    /// The saved journey and leg of a reminder's notification identifier. Leg IDs may contain "|" themselves
    /// (bahn.de's trip IDs), so everything after the journey's ID is the leg's.
    static func target(ofNotificationID identifier: String) -> (entry: UUID, legID: String)? {
        guard identifier.hasPrefix(notificationPrefix) else { return nil }
        let parts = identifier.dropFirst(notificationPrefix.count).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let entry = UUID(uuidString: String(parts[0])), !parts[1].isEmpty else { return nil }
        return (entry, String(parts[1]))
    }
}

/// How a check-in straight from a reminder's "Einchecken" button went (#580), told in the notification that
/// follows. Anything but `.checkedIn` leaves the train to the check-in form, which a tap on it opens.
public enum ReminderCheckinOutcome: Sendable, Hashable {
    case checkedIn
    /// Coupled trains: only the user knows which part they sit in.
    case needsTrainChoice
    /// Träwelling doesn't know the train; the form offers to enter it by hand.
    case trainNotFound
    /// Träwelling has the user on another train at that time; the form offers to check in anyway.
    case collision
    case notLoggedIn
    case failed

    public var title: String {
        self == .checkedIn ? String(kit: "Eingecheckt") : String(kit: "Noch nicht eingecheckt")
    }

    public func body(for leg: Leg) -> String {
        let train = leg.line?.name ?? String(kit: "deinen Zug")
        switch self {
        case .checkedIn:
            return String(kit: "Du bist in %@ nach %@ eingecheckt.", train, leg.destination.displayName)
        case .needsTrainChoice:
            return String(kit: "Tippe hier und wähle, in welchem Zugteil du sitzt.")
        case .trainNotFound:
            return String(kit: "Träwelling kennt %@ nicht. Tippe hier, um ihn selbst einzutragen.", train)
        case .collision:
            return String(kit: "Du bist zu dieser Zeit schon in einem anderen Zug eingecheckt. Tippe hier, um trotzdem einzuchecken.")
        case .notLoggedIn:
            return String(kit: "Tippe hier und melde dich bei Träwelling an.")
        case .failed:
            return String(kit: "Das hat gerade nicht geklappt. Tippe hier, um es noch mal zu versuchen.")
        }
    }
}
