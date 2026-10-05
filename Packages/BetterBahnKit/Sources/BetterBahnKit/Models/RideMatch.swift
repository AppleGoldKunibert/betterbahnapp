import Foundation

/// Recognises the same ride showing up twice — a Träwelling check-in for a journey that's also
/// saved in the app. Neither identical times nor identical line names can be required: a check-in
/// may start a stop later than the saved leg, and Träwelling names lines slightly differently.
public enum RideMatch {
    /// How far apart two records of the same ride may still be.
    static let tolerance: TimeInterval = 15 * 60

    /// Whether both legs describe the same ride: overlapping in time *and* recognisably the same
    /// train (line name, train number) or the same stretch (origin and destination).
    public static func isSameRide(_ a: Leg, _ b: Leg) -> Bool {
        guard overlapsInTime(a, b) else { return false }
        return isSameLine(a.line, b.line) || coversSameStretch(a, b)
    }

    /// Träwelling check-ins that don't already appear in `saved`.
    ///
    /// Bucketed by day so this stays cheap with long histories; a ride is compared against the legs
    /// of its own and the previous day, which covers rides running over midnight.
    public static func deduplicated(_ imported: [Journey], against saved: [Journey],
                                    calendar: Calendar = .current) -> [Journey] {
        var savedByDay: [Date: [Leg]] = [:]
        for leg in saved.flatMap(\.transitLegs) {
            savedByDay[calendar.startOfDay(for: leg.departure.planned), default: []].append(leg)
        }
        return imported.filter { trip in
            !trip.transitLegs.contains { leg in
                let day = calendar.startOfDay(for: leg.departure.planned)
                let previous = calendar.date(byAdding: .day, value: -1, to: day) ?? day
                let candidates = (savedByDay[day] ?? []) + (savedByDay[previous] ?? [])
                return candidates.contains { isSameRide(leg, $0) }
            }
        }
    }

    /// The two rides share time on the rails — you can't sit on two trains at once.
    static func overlapsInTime(_ a: Leg, _ b: Leg) -> Bool {
        a.departure.planned < b.arrival.planned.addingTimeInterval(tolerance)
            && b.departure.planned < a.arrival.planned.addingTimeInterval(tolerance)
    }

    static func isSameLine(_ a: Line?, _ b: Line?) -> Bool {
        guard let a, let b else { return false }
        let left = names(of: a), right = names(of: b)
        if !left.isEmpty, !left.isDisjoint(with: right) { return true }
        // "ICE 645" on one side, a bare product name plus the number on the other.
        if let x = a.number, let y = b.number, !x.isEmpty, x == y { return true }
        return false
    }

    private static func names(of line: Line) -> Set<String> {
        Set(line.allNames.map(Line.normalize)).subtracting([""])
    }

    /// Same start and end, even when the line names disagree (regional lines are often named
    /// differently by each data source).
    static func coversSameStretch(_ a: Leg, _ b: Leg) -> Bool {
        a.origin.isSamePlace(as: b.origin) && a.destination.isSamePlace(as: b.destination)
    }
}
