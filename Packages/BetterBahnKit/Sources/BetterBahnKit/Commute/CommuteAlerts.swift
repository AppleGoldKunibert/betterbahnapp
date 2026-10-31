import Foundation

/// A train of a regular trip's day that is late enough to say so (#397).
public struct CommuteDelay: Sendable, Hashable {
    public var leg: Leg
    public var minutes: Int

    /// One per leg and delay, remembered in `SavedJourney.notifiedIssues`; the delay at the end tells
    /// `CommuteAlerts.delays` how late the train was when it was last reported.
    public var notificationID: String { "\(CommuteAlerts.delayPrefix)\(CommuteAlerts.legKey(leg))|\(minutes)" }

    /// "RE 3: +12 Min."
    public var title: String {
        let train = leg.line?.displayName ?? String(kit: "Zug")
        return String(kit: "%@: +%lld Min.", train, minutes)
    }

    /// "Ab Eberswalde Hbf um 7:54 statt 7:42."
    public var message: String {
        String(kit: "Ab %@ um %@ statt %@.", leg.origin.displayName, RegularTrip.timeString(leg.departure.best),
               RegularTrip.timeString(leg.departure.planned))
    }
}

/// The quiet rules for the journeys saved from a regular trip (#397): nothing while the trains run fine,
/// a notification once a train is `threshold` minutes late, and again only when it got another
/// `growth` minutes later. Cancellations, platform changes and transfers at risk are reported as for
/// any saved journey; a delay reason only for a train that is late enough.
public enum CommuteAlerts {
    static let delayPrefix = "commute-delay|"
    /// A train reported late is reported again once it is this many minutes later still.
    public static let growth = 5

    /// The delays to report now: trains not yet gone (by their live time) and not cancelled that leave
    /// `threshold` minutes late or more, and `growth` minutes later than when they were last reported.
    public static func delays(in journey: Journey, threshold: Int, notified: [String], now: Date = .now) -> [CommuteDelay] {
        journey.transitLegs.compactMap { leg in
            guard !leg.cancelled, leg.departure.best > now, let minutes = leg.departure.delayMinutes,
                  minutes >= threshold else { return nil }
            if let last = lastReported(leg, in: notified), minutes < last + growth { return nil }
            return CommuteDelay(leg: leg, minutes: minutes)
        }
    }

    /// Whether `leg` is late enough for its delay reason to be worth a notification.
    public static func isLateEnough(_ leg: Leg, threshold: Int) -> Bool {
        (leg.departure.delayMinutes ?? 0) >= threshold
    }

    /// Stays the same while a train is refreshed (its trip ID can change when the feed is imported again).
    static func legKey(_ leg: Leg) -> String {
        "\(leg.line?.name ?? "Zug")|\(leg.origin.id)|\(Int(leg.departure.planned.timeIntervalSince1970))"
    }

    private static func lastReported(_ leg: Leg, in notified: [String]) -> Int? {
        let prefix = delayPrefix + legKey(leg) + "|"
        return notified.filter { $0.hasPrefix(prefix) }.compactMap { Int($0.dropFirst(prefix.count)) }.max()
    }
}
