import Foundation

/// When to fetch realtime data next for the journey shown in the Live Activity:
/// - every 2 minutes while waiting for the first train or riding one;
/// - additionally 1 minute before, at, and 1 minute after the current leg's arrival, so it's
///   certain whether the train really arrived;
/// - every minute during a transfer (after that check, until the next train departs).
public enum LiveActivityRefreshSchedule {
    public static let ridingInterval: TimeInterval = 120
    public static let transferInterval: TimeInterval = 60
    /// How far before and after a leg's arrival the extra refreshes happen.
    public static let arrivalCheckOffset: TimeInterval = 60

    public static func nextRefresh(for journey: Journey, after now: Date) -> Date {
        let legs = journey.transitLegs
        let regular = now.addingTimeInterval(ridingInterval)
        for (index, leg) in legs.enumerated() {
            let arrival = leg.arrival.best
            let arrivalCheckEnd = arrival.addingTimeInterval(arrivalCheckOffset)
            if now < arrivalCheckEnd {
                // Waiting for or riding this leg: next arrival check, if it comes before the regular refresh.
                let checks = [arrival.addingTimeInterval(-arrivalCheckOffset), arrival, arrivalCheckEnd]
                let nextCheck = checks.first { $0 > now }
                return min(regular, nextCheck ?? regular)
            }
            // Transferring: this leg has arrived and the next train hasn't left yet.
            if index + 1 < legs.count, now < legs[index + 1].departure.best {
                return now.addingTimeInterval(transferInterval)
            }
        }
        return regular
    }
}
