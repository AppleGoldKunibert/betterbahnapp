import Foundation

extension Trip {
    /// A ring line's vehicle (S41/S42) runs in circles all day, and Transitous' trip for it is that whole
    /// block: the S42 listed 490 stops from 03:51 on, every station 18 or 19 times. Looking a stop up by
    /// its station then finds the first lap, "ab 17:50" turned into "ab 3:50", and every lap's stops
    /// were asked of DB's Timetables under the block's number, which DB doesn't know for a single run.
    /// Needs a station visited at least this often, so a train that merely turns round and passes a
    /// station twice (Berlin Hbf → Halle → back) keeps all its stops.
    static let minimumVisitsOfARingTrip = 3

    /// The one lap of this trip that calls at `station` closest to `time` (the planned time at that
    /// stop): a lap runs from one visit of `station` to the next, so the stop it is opened from starts it
    /// (for an arrival, `arriving`, ends it). The first and last lap of the block are cut at its ends.
    /// `extraBefore` / `extraAfter` add the laps before / after, one more each time the user asks for
    /// them; `hasPreviousLap` / `hasNextLap` of the result say whether there are still more.
    /// `coveringUntil` adds laps after as long as the lap ends before that time, so a leg that deliberately
    /// rides round more than once (Wedding → Gesundbrunnen the long way) keeps its destination.
    /// `nil` when this isn't a trip of repeated laps, or when `station` isn't on it.
    public func lap(at station: Station, near time: Date, arriving: Bool = false,
                    extraBefore: Int = 0, extraAfter: Int = 0, coveringUntil: Date? = nil) -> Trip? {
        let visits = stopovers.indices.filter { stopovers[$0].station.isSamePlace(as: station) }
        guard visits.count >= Self.minimumVisitsOfARingTrip, let lastStop = stopovers.indices.last else { return nil }
        let side: KeyPath<Stopover, TimeInfo?> = arriving ? \.arrival : \.departure
        let other: KeyPath<Stopover, TimeInfo?> = arriving ? \.departure : \.arrival
        func distance(_ index: Int) -> TimeInterval {
            guard let planned = stopovers[index][keyPath: side]?.planned ?? stopovers[index][keyPath: other]?.planned
            else { return .infinity }
            return abs(planned.timeIntervalSince(time))
        }
        guard let visit = visits.min(by: { distance($0) < distance($1) }), distance(visit).isFinite else { return nil }
        // Lap n runs from boundaries[n] to boundaries[n + 1].
        var boundaries = visits
        if boundaries[0] > 0 { boundaries.insert(0, at: 0) }
        if boundaries[boundaries.count - 1] < lastStop { boundaries.append(lastStop) }
        guard let position = boundaries.firstIndex(of: visit) else { return nil }
        let lastLap = boundaries.count - 2
        let shown = arriving ? max(position - 1, 0) : min(position, lastLap)
        let first = max(shown - max(extraBefore, 0), 0)
        var last = min(shown + max(extraAfter, 0), lastLap)
        while last < lastLap, let until = coveringUntil,
              let end = stopovers[boundaries[last + 1]].arrival?.planned ?? stopovers[boundaries[last + 1]].departure?.planned,
              end < until {
            last += 1
        }
        var lap = self
        lap.stopovers = Array(stopovers[boundaries[first]...boundaries[last + 1]])
        lap.hasPreviousLap = first > 0
        lap.hasNextLap = last < lastLap
        return lap
    }
}
