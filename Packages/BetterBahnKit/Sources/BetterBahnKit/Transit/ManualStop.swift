import Foundation

public extension Stopover {
    /// A stop the user adds by hand: the train halted somewhere its timetable doesn't have, e.g. the
    /// doors were opened at a station during a disruption so passengers could change trains (#207).
    /// `time` is when it was there; there is no live data for it, so no delay shows.
    static func manual(at station: Station, time: Date) -> Stopover {
        let time = TimeInfo(planned: time, actual: nil)
        return Stopover(station: station, arrival: time, departure: time, arrivalPlatform: nil,
                        departurePlatform: nil, cancelled: false, isManual: true)
    }
}

public extension Trip {
    /// The trip with `stop` placed among its stops by time: before the first stop after boarding at
    /// `origin` that the train reaches later (live times where known), or at the end. A manual stop
    /// added before is replaced. `nil` if `origin` isn't on the trip or `stop` is a stop it already has.
    func inserting(manualStop stop: Stopover, boardingAt origin: Station) -> Trip? {
        var stops = stopovers.filter { !$0.isManual }
        guard let boarding = stops.firstIndex(where: { $0.station.isSamePlace(as: origin) }),
              !stops[(boarding + 1)...].contains(where: { $0.station.isSamePlace(as: stop.station) }) else { return nil }
        let time = stop.arrival?.best ?? stop.departure?.best ?? .distantFuture
        let index = stops[(boarding + 1)...].firstIndex { other in
            (other.arrival?.best ?? other.departure?.best ?? .distantPast) > time
        } ?? stops.endIndex
        stops.insert(stop, at: index)
        var trip = self
        trip.stopovers = stops
        return trip
    }
}
