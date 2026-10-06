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

    /// Träwelling check-ins that don't already appear in `saved` or earlier in `imported`.
    ///
    /// The same ride can be in the check-in history more than once (a check-in deleted and redone
    /// on Träwelling stays in the local copy), so check-ins are matched against each other too.
    /// Otherwise those rides only collapsed while saved journeys were shown, and hiding them made
    /// the stretches look travelled more often.
    ///
    /// Bucketed by day so this stays cheap with long histories; a ride is compared against the legs
    /// of its own and the previous day, which covers rides running over midnight.
    public static func deduplicated(_ imported: [Journey], against saved: [Journey] = [],
                                    calendar: Calendar = .current) -> [Journey] {
        var seenByDay: [Date: [Leg]] = [:]
        func remember(_ legs: [Leg]) {
            for leg in legs {
                seenByDay[calendar.startOfDay(for: leg.departure.planned), default: []].append(leg)
            }
        }
        remember(saved.flatMap(\.transitLegs))
        return imported.filter { trip in
            let isKnown = trip.transitLegs.contains { leg in
                let day = calendar.startOfDay(for: leg.departure.planned)
                let previous = calendar.date(byAdding: .day, value: -1, to: day) ?? day
                let candidates = (seenByDay[day] ?? []) + (seenByDay[previous] ?? [])
                return candidates.contains { isSameRide(leg, $0) }
            }
            if !isKnown { remember(trip.transitLegs) }
            return !isKnown
        }
    }

    /// `saved` reduced to the legs no Träwelling check-in in `checkins` covers; journeys left without
    /// a ride are dropped.
    ///
    /// A check-in is what was actually ridden, so it wins over the plan: a saved leg running at the
    /// same time as a check-in goes, whatever train it names — you can't sit on two trains at once,
    /// so it's either that same ride or a plan that wasn't taken. Dropping whole check-ins in favour
    /// of saved journeys instead made turning saved journeys on swap rides for differently drawn
    /// copies (and add plans next to the train really taken), so stretches showed up twice and a
    /// saved journey with three legs replaced three trips with one. This way it only ever adds
    /// rides nobody checked in. The same ride saved twice counts once, too.
    public static func uncovered(_ saved: [Journey], by checkins: [Journey],
                                 calendar: Calendar = .current) -> [Journey] {
        func day(of leg: Leg) -> Date { calendar.startOfDay(for: leg.departure.planned) }
        func around(_ day: Date) -> [Date] {
            [-1, 0, 1].map { calendar.date(byAdding: .day, value: $0, to: day) ?? day }
        }
        let checkedIn = Dictionary(grouping: checkins.flatMap(\.transitLegs), by: day(of:))
        var keptByDay: [Date: [Leg]] = [:]
        return saved.compactMap { journey in
            let legs = journey.legs.filter { leg in
                guard !leg.isWalking else { return false }
                // Neighbouring days too, for rides running over midnight.
                let days = around(day(of: leg))
                if days.contains(where: { checkedIn[$0, default: []].contains { runSimultaneously(leg, $0) } }) {
                    return false
                }
                if days.contains(where: { keptByDay[$0, default: []].contains { isSameRide(leg, $0) } }) {
                    return false
                }
                keptByDay[day(of: leg), default: []].append(leg)
                return true
            }
            return legs.isEmpty ? nil : Journey(legs: legs, source: journey.source)
        }
    }

    /// Both rides are under way at the same moment, by plan. No tolerance: a connection leaving
    /// the minute the check-in arrives is a ride of its own.
    static func runSimultaneously(_ a: Leg, _ b: Leg) -> Bool {
        a.departure.planned < b.arrival.planned && b.departure.planned < a.arrival.planned
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
