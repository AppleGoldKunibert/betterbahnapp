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
    /// stop): from that visit up to the next visit of the same station, or for an arrival (`arriving`)
    /// from the previous visit up to it. `nil` when this isn't a trip of repeated laps, or when `station`
    /// isn't on it.
    public func lap(at station: Station, near time: Date, arriving: Bool = false) -> Trip? {
        let visits = stopovers.indices.filter { stopovers[$0].station.isSamePlace(as: station) }
        guard visits.count >= Self.minimumVisitsOfARingTrip else { return nil }
        let side: KeyPath<Stopover, TimeInfo?> = arriving ? \.arrival : \.departure
        let other: KeyPath<Stopover, TimeInfo?> = arriving ? \.departure : \.arrival
        func distance(_ index: Int) -> TimeInterval {
            guard let planned = stopovers[index][keyPath: side]?.planned ?? stopovers[index][keyPath: other]?.planned
            else { return .infinity }
            return abs(planned.timeIntervalSince(time))
        }
        guard let visit = visits.min(by: { distance($0) < distance($1) }), distance(visit).isFinite,
              let position = visits.firstIndex(of: visit) else { return nil }
        let range: ClosedRange<Int>
        if arriving {
            range = (position > 0 ? visits[position - 1] : 0)...visit
        } else {
            range = visit...(position + 1 < visits.count ? visits[position + 1] : stopovers.count - 1)
        }
        var lap = self
        lap.stopovers = Array(stopovers[range])
        return lap
    }
}
