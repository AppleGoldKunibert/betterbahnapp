import Foundation

/// The widgets' countdowns: a running timer ("11:59:59") up to `liveLimit` ahead, further out days,
/// hours and minutes ("2d 3h 49m"). WidgetKit can't count that down by itself, so the widgets add a
/// timeline entry at every minute it changes (`tickDates`).
public enum WidgetTimer {
    /// Countdowns longer than this read "2d 3h 49m" instead of a running timer.
    public static let liveLimit: TimeInterval = 12 * 3600

    /// "2d 3h 49m" ("13h 5m" under a day) from `date` to `end`, rounded up to whole minutes, so it
    /// changes exactly at `tickDates`; nil within `liveLimit`, where the running timer is shown.
    public static func longText(from date: Date, to end: Date) -> String? {
        // Whole seconds, so a tick computed as `end - n minutes` doesn't round up to n + 1.
        let seconds = Int(end.timeIntervalSince(date).rounded())
        guard seconds > Int(liveLimit) else { return nil }
        let minutes = (seconds + 59) / 60
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        return days > 0 ? "\(days)d \(hours)h \(rest)m" : "\(hours)h \(rest)m"
    }

    /// The moments after `now` and up to `until` at which `longText` changes: every whole minute
    /// before `end`, the last one where the running timer takes over (`liveLimit` before `end`).
    public static func tickDates(to end: Date, after now: Date, until: Date) -> [Date] {
        let last = min(until, end.addingTimeInterval(-liveLimit))
        var dates: [Date] = []
        var minutes = Int((end.timeIntervalSince(now) / 60).rounded(.up)) - 1
        while minutes >= 0 {
            let date = end.addingTimeInterval(-Double(minutes) * 60)
            guard date <= last else { break }
            if date > now { dates.append(date) }
            minutes -= 1
        }
        return dates
    }
}
