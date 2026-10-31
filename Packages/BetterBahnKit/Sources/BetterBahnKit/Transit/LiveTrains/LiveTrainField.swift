import Foundation

/// A train drawn on a map at one moment.
public struct LiveTrainMarker: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var coordinate: Coordinate
    /// The stop the train runs to next (display name), when known.
    public var nextStop: String?
    public var speedKmh: Double?
    public var isLongDistance: Bool
    /// Whether the marker moves along the track between refreshes; bahn.jetzt-only trains stay put.
    public var followsTrack: Bool
}

/// Every train on the map: Transitous' stretches between stops give the track and the timetable,
/// bahn.jetzt's fixes (where it knows the train) the real position and speed. In between refreshes a
/// train runs on along its track at its last speed, or by the timetable when bahn.jetzt doesn't know it.
public struct LiveTrainField: Sendable {
    /// A bahn.jetzt fix older than this no longer moves the train; the timetable takes over.
    public static let maxExtrapolation: TimeInterval = 90
    /// How far off a trip's track a bahn.jetzt fix may be and still count as that train.
    static let maxDistanceFromTrack: Double = 1_500
    /// How far a regional fix may be from where the timetable puts the train (several trains share a line name).
    static let maxDistanceFromSchedule: Double = 15_000
    /// Own trains are drawn separately; another marker with the same name this close is the same train.
    static let ownTrainRadius: Double = 3_000

    struct Trip: Sendable {
        var id: String
        var name: String
        var runNumber: Int?
        var isLongDistance: Bool
        /// By departure.
        var segments: [LiveTrainSegment]
    }

    struct Anchor: Sendable {
        var segment: Int
        var meters: Double
        var time: Date
        var metersPerSecond: Double
        var speedKmh: Double?
    }

    let trips: [Trip]
    let anchors: [String: Anchor]
    /// bahn.jetzt trains no trip matched; shown where bahn.jetzt last saw them.
    let unmatched: [BahnJetztClient.RunningTrain]
    let ownTrains: [(name: String, coordinate: Coordinate)]

    /// - Parameter ownTrains: the user's own trains, which the map draws itself and which are left out here.
    public init(segments: [LiveTrainSegment], running: [BahnJetztClient.RunningTrain],
                ownTrains: [(name: String, coordinate: Coordinate)] = []) {
        let trips = Dictionary(grouping: segments, by: \.tripId).map { id, segments in
            let sorted = segments.sorted { $0.departure < $1.departure }
            return Trip(id: id, name: sorted[0].name, runNumber: sorted[0].runNumber, isLongDistance: sorted.contains(where: \.isLongDistance), segments: sorted)
        }
        .sorted { $0.id < $1.id }
        let byName = Dictionary(grouping: running, by: { Self.normalized($0.name) })
            .merging(Dictionary(grouping: running.filter { $0.lineName != nil }, by: { Self.normalized($0.lineName!) }),
                     uniquingKeysWith: { $0 + $1 })
        let regionalByNumber = Dictionary(grouping: running.filter { train in
            train.number != nil && !(train.category.map { BahnDeClient.longDistanceCategories.contains($0.uppercased()) } ?? false)
        }, by: { $0.number! })

        // Best fix per trip; a bahn.jetzt train serves one trip only, the closest match first.
        var candidates: [(trip: String, train: String, anchor: Anchor, score: Double)] = []
        for trip in trips {
            // A regional run number names the train; feeds disagree on RE vs. RB and the line's spelling.
            let trains = trip.runNumber.flatMap { regionalByNumber[$0] } ?? byName[Self.normalized(trip.name)] ?? []
            for train in Set(trains) {
                if let (anchor, score) = Self.anchor(of: train, on: trip) {
                    candidates.append((trip.id, train.id, anchor, score))
                }
            }
        }
        var anchors: [String: Anchor] = [:]
        var usedTrains = Set<String>()
        for candidate in candidates.sorted(by: { $0.score < $1.score })
        where anchors[candidate.trip] == nil && !usedTrains.contains(candidate.train) {
            anchors[candidate.trip] = candidate.anchor
            usedTrains.insert(candidate.train)
        }
        self.trips = trips
        self.anchors = anchors
        self.unmatched = running.filter { !usedTrains.contains($0.id) }
        self.ownTrains = ownTrains
    }

    /// Where bahn.jetzt's fix puts `train` on `trip`, and how good a match that is (lower is better).
    static func anchor(of train: BahnJetztClient.RunningTrain, on trip: Trip) -> (Anchor, Double)? {
        let fix = train.position
        var best: (segment: Int, meters: Double, distance: Double)?
        for (index, segment) in trip.segments.enumerated() {
            guard let located = segment.track.locate(fix.coordinate), located.distance <= maxDistanceFromTrack else { continue }
            if best == nil || located.distance < best!.distance { best = (index, located.meters, located.distance) }
        }
        guard let best else { return nil }
        // Off the timetable by more than a few kilometers: another train of the same line.
        let scheduled = schedulePosition(on: trip, at: fix.time)
        let offSchedule = scheduled?.coordinate.distance(to: fix.coordinate) ?? 0
        if !trip.isLongDistance, offSchedule > maxDistanceFromSchedule { return nil }
        let speed = max(0, fix.speedKmh ?? 0) / 3.6
        return (Anchor(segment: best.segment, meters: best.meters, time: fix.time, metersPerSecond: speed, speedKmh: fix.speedKmh),
                best.distance + offSchedule * 0.1)
    }

    /// Where the timetable puts the train at `date`: on the stretch it's running, at the stop it's
    /// waiting at, or nil before it starts (more than a minute ahead) and once it has arrived.
    static func schedulePosition(on trip: Trip, at date: Date) -> (segment: Int, coordinate: Coordinate)? {
        let segments = trip.segments
        if let index = segments.firstIndex(where: { $0.departure <= date && date <= $0.arrival }) {
            let segment = segments[index]
            return segment.track.coordinate(at: segment.scheduledMeters(at: date)).map { (index, $0) }
        }
        // Waiting at a stop between two stretches.
        if let index = segments.lastIndex(where: { $0.arrival < date }), index + 1 < segments.count {
            return segments[index].track.points.last.map { (index, $0) }
        }
        // About to leave, or just arrived where the loaded stretches end.
        if let first = segments.first, date < first.departure, first.departure.timeIntervalSince(date) <= 60 {
            return first.track.points.first.map { (0, $0) }
        }
        if let last = segments.last, date > last.arrival, date.timeIntervalSince(last.arrival) <= 60 {
            return last.track.points.last.map { (segments.count - 1, $0) }
        }
        return nil
    }

    /// The trains at `date`.
    /// - Parameters:
    ///   - area: only trains inside it (nil: all).
    ///   - limit: at most this many, the ones closest to the middle of `area` first.
    public func markers(at date: Date, in area: MapArea? = nil, limit: Int = .max) -> [LiveTrainMarker] {
        var markers: [LiveTrainMarker] = []
        for trip in trips {
            if let marker = marker(for: trip, at: date) { markers.append(marker) }
        }
        for train in unmatched {
            markers.append(LiveTrainMarker(id: "bahn.jetzt:\(train.id)", name: train.name, coordinate: train.position.coordinate,
                                           nextStop: nil, speedKmh: train.position.speedKmh,
                                           isLongDistance: train.category.map { BahnDeClient.longDistanceCategories.contains($0.uppercased()) } ?? false,
                                           followsTrack: false))
        }
        markers.removeAll { marker in
            (area.map { !$0.contains(marker.coordinate) } ?? false) || ownTrains.contains {
                Self.normalized($0.name) == Self.normalized(marker.name) && $0.coordinate.distance(to: marker.coordinate) < Self.ownTrainRadius
            }
        }
        guard markers.count > limit, let center = area?.center else { return Array(markers.prefix(limit)) }
        return Array(markers.sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }.prefix(limit))
    }

    func marker(for trip: Trip, at date: Date) -> LiveTrainMarker? {
        let place: (segment: Int, coordinate: Coordinate)
        var speed: Double?
        if let anchor = anchors[trip.id], date.timeIntervalSince(anchor.time) <= Self.maxExtrapolation {
            let segment = trip.segments[anchor.segment]
            // Runs on at its last speed, but never past the next stop.
            let meters = min(segment.track.length, anchor.meters + anchor.metersPerSecond * max(0, date.timeIntervalSince(anchor.time)))
            guard let coordinate = segment.track.coordinate(at: meters) else { return nil }
            place = (anchor.segment, coordinate)
            speed = anchor.speedKmh
        } else if let scheduled = Self.schedulePosition(on: trip, at: date) {
            place = scheduled
        } else {
            return nil
        }
        let segment = trip.segments[place.segment]
        return LiveTrainMarker(id: trip.id, name: trip.name, coordinate: place.coordinate, nextStop: Station.displayName(for: segment.to),
                               speedKmh: speed, isLongDistance: trip.isLongDistance, followsTrack: true)
    }

    /// "ICE 79", "ice79" and "ICE  79" are the same train.
    static func normalized(_ name: String) -> String {
        name.uppercased().filter { !$0.isWhitespace }
    }
}

/// Which part of the map Transitous' trains were loaded for, and when to load again.
public struct LiveTrainCoverage: Sendable, Hashable {
    public var area: MapArea
    public var until: Date

    public init(area: MapArea, until: Date) {
        self.area = area
        self.until = until
    }

    /// How far ahead one load reaches.
    public static let window: TimeInterval = 20 * 60
    /// Loaded again this long before the window runs out.
    public static let refreshMargin: TimeInterval = 2 * 60
    /// Zoomed out further than this (degrees on screen), nothing is loaded: the answer would be megabytes.
    public static let maxLatitudeSpan: Double = 2.5
    public static let maxLongitudeSpan: Double = 4
    /// What's loaded around the visible area, so small pans need nothing new.
    static let margin = 0.25

    /// The area to load for `visible`, or nil when what's loaded still covers it (or it's too large).
    public static func areaToLoad(visible: MapArea, loaded: LiveTrainCoverage?, now: Date = .now) -> MapArea? {
        guard visible.latitudeSpan <= maxLatitudeSpan, visible.longitudeSpan <= maxLongitudeSpan else { return nil }
        if let loaded, loaded.area.contains(visible), loaded.until.timeIntervalSince(now) > refreshMargin { return nil }
        return visible.expanded(by: margin)
    }

    /// Transitous' zoom level for `area`; from 9 on it includes regional trains.
    public static func zoom(for area: MapArea) -> Int {
        let zoom = Int(log2(360 / max(area.longitudeSpan, 0.001)).rounded())
        return min(14, max(9, zoom))
    }
}
