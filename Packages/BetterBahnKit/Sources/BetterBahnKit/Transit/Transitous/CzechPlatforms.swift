import Foundation

/// Platforms in Czechia for trains from feeds that have none there. DB's feed (DELFI), ZSSK's and
/// ÖBB's run the Berlin–Praha trains all the way to Praha, but without a single platform past the
/// border. The Czech national timetable (CZPTT, Správa železnic's, also in Transitous) has the same
/// train from the border on, under its own name ("rj 171" for DB's "ICE 171", "EC 355" for alex'
/// "RE25 (355)"), with the planned track at every stop. That train is found by its number on the
/// stop times of the first Czech stop and its tracks are taken over, marked as planned only
/// (`PlatformInfo.Source.czechTimetable`): Transitous has no live data from CZPTT.
extension TransitousProvider {
    static let czechTimetableFeed = "cz-CZPTT_"

    /// How far the same stop's planned time may differ between the feeds: DELFI's and CZPTT's agree
    /// to the minute, European Sleeper's is a few minutes off (ES 453 at Praha hl.n. 8:54 / 8:51).
    static let czechTimetableTolerance: TimeInterval = 5 * 60

    /// Whether `station` is in Czechia, from the UIC station number (54…) in its stop ID: "000005400003"
    /// (Děčín hl.n. in DELFI), "5455659" (ZSSK, European Sleeper), "cz:0:5455659:1:1" (ÖBB), or a CZPTT stop.
    static func isCzechStop(_ station: Station) -> Bool {
        if station.id.hasPrefix(czechTimetableFeed) { return station.id.contains(":CZ:") }
        let local = station.id.split(separator: "_", maxSplits: 1).last ?? Substring(station.id)
        return local.split(separator: ":").contains { part in
            let digits = part.drop { $0 == "0" }
            return digits.count == 7 && digits.hasPrefix("54") && digits.allSatisfy(\.isNumber)
        }
    }

    /// Whether `leg` is a train from another feed than CZPTT missing a platform at a Czech stop.
    static func lacksCzechPlatforms(_ leg: Leg) -> Bool {
        guard !leg.isWalking, leg.source == .transitous, leg.line?.product.isTrain == true, leg.line?.number != nil,
              let tripId = leg.tripId, !tripId.contains(czechTimetableFeed) else { return false }
        if isCzechStop(leg.origin), leg.departurePlatform?.best == nil { return true }
        if isCzechStop(leg.destination), leg.arrivalPlatform?.best == nil { return true }
        return lacksCzechPlatforms(leg.stopovers)
    }

    /// Whether `trip` is a train from another feed than CZPTT missing a platform at a Czech stop.
    static func lacksCzechPlatforms(_ trip: Trip) -> Bool {
        guard trip.source == .transitous, trip.line?.product.isTrain == true, trip.line?.number != nil,
              !trip.id.contains(czechTimetableFeed) else { return false }
        return lacksCzechPlatforms(trip.stopovers)
    }

    private static func lacksCzechPlatforms(_ stopovers: [Stopover]) -> Bool {
        stopovers.contains { stop in
            isCzechStop(stop.station)
                && ((stop.arrival != nil && stop.arrivalPlatform?.best == nil)
                    || (stop.departure != nil && stop.departurePlatform?.best == nil))
        }
    }

    /// `leg` with the platforms it lacks taken from CZPTT's run of the same train (see above);
    /// unchanged if it lacks none in Czechia or that run isn't found.
    public func fillingCzechPlatforms(in leg: Leg) async -> Leg {
        guard Self.lacksCzechPlatforms(leg), let number = leg.line?.number else { return leg }
        let stops = leg.stopovers.isEmpty ? [Self.departureStop(of: leg), Self.arrivalStop(of: leg)] : leg.stopovers
        guard let timetable = await czechTimetableStops(number: number, along: stops) else { return leg }
        return Self.fillingCzechPlatforms(in: leg, from: timetable)
    }

    /// Like `fillingCzechPlatforms(in:)` for a leg, for a whole train run.
    public func fillingCzechPlatforms(in trip: Trip) async -> Trip {
        guard Self.lacksCzechPlatforms(trip), let number = trip.line?.number,
              let timetable = await czechTimetableStops(number: number, along: trip.stopovers) else { return trip }
        var trip = trip
        trip.stopovers = Self.fillingPlatforms(of: trip.stopovers, from: timetable)
        return trip
    }

    /// For each leg lacking platforms in Czechia, CZPTT's stops of the same train, keyed by `Leg.id`
    /// (for `fillingCzechPlatforms(in:from:)`). Legs it wasn't found for are left out.
    public func czechTimetableStops(for legs: [Leg]) async -> [String: [Stopover]] {
        let candidates = Dictionary(legs.filter(Self.lacksCzechPlatforms).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !candidates.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, [Stopover]?).self) { group in
            for leg in candidates.values {
                group.addTask {
                    guard let number = leg.line?.number else { return (leg.id, nil) }
                    let stops = leg.stopovers.isEmpty ? [Self.departureStop(of: leg), Self.arrivalStop(of: leg)] : leg.stopovers
                    return (leg.id, await czechTimetableStops(number: number, along: stops))
                }
            }
            var result: [String: [Stopover]] = [:]
            for await (id, stops) in group { if let stops { result[id] = stops } }
            return result
        }
    }

    /// CZPTT's stops (with their planned tracks) of train `number` running along `stops`, found at
    /// the first Czech stop with a time; nil if there is none or the train isn't found there.
    /// Cached for the day: the timetable doesn't change in between.
    func czechTimetableStops(number: String, along stops: [Stopover]) async -> [Stopover]? {
        guard let anchor = stops.first(where: { Self.isCzechStop($0.station) && $0.station.coordinate != nil
            && ($0.departure ?? $0.arrival) != nil }),
              let coordinate = anchor.station.coordinate else { return nil }
        let kind: BoardKind = anchor.departure != nil ? .departures : .arrivals
        guard let planned = (anchor.departure ?? anchor.arrival)?.planned else { return nil }
        let key = "\(number)|\(coordinate.latitude),\(coordinate.longitude)|\(kind)|\(planned.timeIntervalSince1970)"
        let found = try? await czechTimetableCache.value(for: key, maxAge: 12 * 3600) {
            try await czechTimetableRun(number: number, near: coordinate, kind: kind, planned: planned)
        }
        guard let found, !found.isEmpty else { return nil }
        return found
    }

    private func czechTimetableRun(number: String, near coordinate: Coordinate, kind: BoardKind,
                                   planned: Date) async throws -> [Stopover]? {
        guard let stopId = try await czechTimetableStop(near: coordinate) else { return nil }
        let window = Self.czechTimetableTolerance
        let stopTimes = try await fetchStopTimes(
            stopId: stopId, date: planned.addingTimeInterval(-window), duration: Int(2 * window / 60), kind: kind,
            modes: Self.trainModes, count: 60)
        guard let run = Self.sameTrain(number: number, kind: kind, planned: planned, in: stopTimes) else { return nil }
        return try await trip(id: run.tripId).stopovers
    }

    /// The modes CZPTT's trains run as (long-distance, regional), for the stop times request.
    private static let trainModes = ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_FAST_RAIL", "REGIONAL_RAIL"]

    /// CZPTT's run of train `number` among `stopTimes`, at `planned` give or take a few minutes.
    static func sameTrain(number: String, kind: BoardKind, planned: Date, in stopTimes: [MStopTime]) -> MStopTime? {
        stopTimes
            .filter { stopTime in
                let time = kind == .departures ? stopTime.place.scheduledDeparture : stopTime.place.scheduledArrival
                guard stopTime.tripId.contains(czechTimetableFeed), stopTime.lineInfo.toLine().number == number,
                      let time else { return false }
                return abs(time.timeIntervalSince(planned)) <= czechTimetableTolerance
            }
            .min { a, b in
                let timeA = (kind == .departures ? a.place.scheduledDeparture : a.place.scheduledArrival) ?? .distantFuture
                let timeB = (kind == .departures ? b.place.scheduledDeparture : b.place.scheduledArrival) ?? .distantFuture
                return abs(timeA.timeIntervalSince(planned)) < abs(timeB.timeIntervalSince(planned))
            }
    }

    /// CZPTT's station at `coordinate` ("cz-CZPTT_czptt:stop:CZ:55659" for Děčín hl.n.), from the stops
    /// Transitous has around it. Looked up by place: other feeds spell the name without its accents
    /// ("Decin hl.n.") or shortened, and the geocoder doesn't find CZPTT's station by those.
    func czechTimetableStop(near coordinate: Coordinate) async throws -> String? {
        let span = 0.005  // about 500 m north–south, 350 m east–west
        let items: [URLQueryItem] = [
            .init(name: "min", value: "\(coordinate.latitude - span),\(coordinate.longitude - span)"),
            .init(name: "max", value: "\(coordinate.latitude + span),\(coordinate.longitude + span)"),
        ]
        let stops = try await http.get(url("v1/map/stops", items), as: [MPlace].self,
                                       headers: ["User-Agent": HTTPClient.identifyingUserAgent])
        return Self.czechTimetableStation(near: coordinate, among: stops)
    }

    /// The nearest CZPTT station among `stops`, as its station ID without the platform part
    /// ("…:CZ:55659:platform:1" → "…:CZ:55659").
    static func czechTimetableStation(near coordinate: Coordinate, among stops: [MPlace]) -> String? {
        stops
            .compactMap { stop -> (String, Double)? in
                guard let id = stop.stopId,
                      let range = id.range(of: #"^cz-CZPTT_czptt:stop:CZ:\d+"#, options: .regularExpression) else { return nil }
                return (String(id[range]), Coordinate(latitude: stop.lat, longitude: stop.lon).distance(to: coordinate))
            }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: Filling in

    /// `leg` with every platform it lacks – at its start, its end and its stops – taken from `timetable`
    /// (CZPTT's stops of the same train), marked `.czechTimetable`. A stop is matched by place and planned time.
    public static func fillingCzechPlatforms(in leg: Leg, from timetable: [Stopover]) -> Leg {
        var leg = leg
        if leg.departurePlatform?.best == nil {
            leg.departurePlatform = platform(in: timetable, at: departureStop(of: leg), side: \.departure) ?? leg.departurePlatform
        }
        if leg.arrivalPlatform?.best == nil {
            leg.arrivalPlatform = platform(in: timetable, at: arrivalStop(of: leg), side: \.arrival) ?? leg.arrivalPlatform
        }
        leg.stopovers = fillingPlatforms(of: leg.stopovers, from: timetable)
        return leg
    }

    static func fillingPlatforms(of stopovers: [Stopover], from timetable: [Stopover]) -> [Stopover] {
        stopovers.map { stop in
            var stop = stop
            if stop.arrival != nil, stop.arrivalPlatform?.best == nil {
                stop.arrivalPlatform = platform(in: timetable, at: stop, side: \.arrival) ?? stop.arrivalPlatform
            }
            if stop.departure != nil, stop.departurePlatform?.best == nil {
                stop.departurePlatform = platform(in: timetable, at: stop, side: \.departure) ?? stop.departurePlatform
            }
            return stop
        }
    }

    /// The platform of `stop`'s `side` in `timetable`: the stop at the same place whose time on that
    /// side (or, at the timetable's first or last stop, the other one) is planned within the tolerance.
    private static func platform(in timetable: [Stopover], at stop: Stopover, side: KeyPath<Stopover, TimeInfo?>) -> PlatformInfo? {
        guard let planned = stop[keyPath: side]?.planned else { return nil }
        let match = timetable.first { candidate in
            guard candidate.station.isSamePlace(as: stop.station),
                  let time = candidate[keyPath: side] ?? candidate.arrival ?? candidate.departure else { return false }
            return abs(time.planned.timeIntervalSince(planned)) <= czechTimetableTolerance
        }
        guard let match, let track = (side == \Stopover.arrival ? match.arrivalPlatform : match.departurePlatform)?.best
            ?? match.arrivalPlatform?.best ?? match.departurePlatform?.best else { return nil }
        return PlatformInfo(planned: track, actual: nil, source: .czechTimetable)
    }

    private static func departureStop(of leg: Leg) -> Stopover {
        Stopover(station: leg.origin, arrival: nil, departure: leg.departure,
                 arrivalPlatform: nil, departurePlatform: leg.departurePlatform, cancelled: false)
    }

    private static func arrivalStop(of leg: Leg) -> Stopover {
        Stopover(station: leg.destination, arrival: leg.arrival, departure: nil,
                 arrivalPlatform: leg.arrivalPlatform, departurePlatform: nil, cancelled: false)
    }
}
