import Foundation

/// A rectangle on the map, e.g. what's on screen.
public struct MapArea: Sendable, Hashable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    public init(center: Coordinate, latitudeSpan: Double, longitudeSpan: Double) {
        self.init(south: center.latitude - latitudeSpan / 2, west: center.longitude - longitudeSpan / 2,
                  north: center.latitude + latitudeSpan / 2, east: center.longitude + longitudeSpan / 2)
    }

    public var latitudeSpan: Double { north - south }
    public var longitudeSpan: Double { east - west }
    public var center: Coordinate { Coordinate(latitude: (south + north) / 2, longitude: (west + east) / 2) }

    public func contains(_ point: Coordinate) -> Bool {
        (south ... north).contains(point.latitude) && (west ... east).contains(point.longitude)
    }

    public func contains(_ other: MapArea) -> Bool {
        south <= other.south && west <= other.west && north >= other.north && east >= other.east
    }

    /// Grown by `fraction` of its span on every side.
    public func expanded(by fraction: Double) -> MapArea {
        MapArea(south: max(-90, south - latitudeSpan * fraction), west: max(-180, west - longitudeSpan * fraction),
                north: min(90, north + latitudeSpan * fraction), east: min(180, east + longitudeSpan * fraction))
    }
}

/// One train between two stops, from Transitous' map: the track it runs on and when it leaves and
/// arrives (with real-time data where the feed has it).
public struct LiveTrainSegment: Sendable, Hashable {
    public var tripId: String
    /// e.g. "ICE 79", "RE8", "S3".
    public var name: String
    /// A regional train's run number, which Transitous adds to the line ("RB58 (4761)").
    public var runNumber: Int?
    public var from: String
    public var to: String
    public var departure: Date
    public var arrival: Date
    public var track: TrackPath
    public var isLongDistance: Bool

    public init(tripId: String, name: String, runNumber: Int? = nil, from: String, to: String, departure: Date, arrival: Date,
                track: TrackPath, isLongDistance: Bool) {
        self.tripId = tripId
        self.name = name
        self.runNumber = runNumber
        self.from = from
        self.to = to
        self.departure = departure
        self.arrival = arrival
        self.track = track
        self.isLongDistance = isLongDistance
    }

    /// Meters along the track at `date`, assuming an even pace between the two stops.
    public func scheduledMeters(at date: Date) -> Double {
        let duration = arrival.timeIntervalSince(departure)
        guard duration > 0 else { return date < departure ? 0 : track.length }
        return track.length * max(0, min(1, date.timeIntervalSince(departure) / duration))
    }
}

// MARK: - Transitous

extension TransitousProvider {
    struct MTripSegment: Decodable {
        struct Trip: Decodable { var tripId: String; var routeShortName: String? }
        struct Place: Decodable { var name: String }
        var trips: [Trip]
        var mode: String
        var from: Place
        var to: Place
        var departure: Date
        var arrival: Date
        var polyline: String
    }

    /// Train modes worth showing; buses, trams and the like are dropped.
    static let liveTrainModes: Set<String> = [
        "HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_FAST_RAIL", "REGIONAL_RAIL", "SUBURBAN", "RAIL",
    ]

    /// Whether a stretch is a train worth showing. Some feeds file S-Bahns as metro ("S3"), which
    /// otherwise also covers U-Bahns and trams.
    static func isLiveTrain(mode: String, name: String) -> Bool {
        if liveTrainModes.contains(mode) { return true }
        return mode == "METRO" && name.wholeMatch(of: /S ?\d+[A-Z]?/) != nil
    }

    /// "RB58 (4761)" → ("RB58", 4761).
    static func splitRunNumber(_ name: String) -> (name: String, runNumber: Int?) {
        guard let match = name.firstMatch(of: /^(.+?)\s*\((\d+)\)$/) else { return (name, nil) }
        return (String(match.1), Int(match.2))
    }
    static let liveLongDistanceModes: Set<String> = ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"]

    /// Every train running in `area` between `start` and `end`, one entry per stretch between two stops.
    /// - Parameter zoom: the map zoom level; Transitous leaves out regional trains below about 9.
    public func liveTrainSegments(in area: MapArea, zoom: Int, from start: Date, to end: Date) async throws -> [LiveTrainSegment] {
        let items: [URLQueryItem] = [
            .init(name: "min", value: "\(area.south),\(area.west)"),
            .init(name: "max", value: "\(area.north),\(area.east)"),
            .init(name: "zoom", value: String(zoom)),
            .init(name: "startTime", value: JSONDecoding.isoString(start)),
            .init(name: "endTime", value: JSONDecoding.isoString(end)),
        ]
        let segments = try await http.get(url("v1/map/trips", items), as: [MTripSegment].self,
                                          headers: ["User-Agent": HTTPClient.identifyingUserAgent])
        return Self.liveTrainSegments(from: segments)
    }

    static func liveTrainSegments(from segments: [MTripSegment]) -> [LiveTrainSegment] {
        var seen = Set<String>()
        return segments.compactMap { segment in
            guard let trip = segment.trips.first,
                  let fullName = trip.routeShortName?.trimmingCharacters(in: .whitespaces), !fullName.isEmpty,
                  case let (name, runNumber) = splitRunNumber(fullName), isLiveTrain(mode: segment.mode, name: name),
                  // Night buses ("20N") are sometimes filed as long-distance trains; trains' names start with a letter.
                  name.first?.isLetter == true,
                  seen.insert("\(trip.tripId)|\(segment.departure.timeIntervalSince1970)").inserted else { return nil }
            // The map's polylines have 5 decimals, unlike the 6 of `v5/plan`.
            let points = Polyline.decode(segment.polyline, precision: 5)
            guard points.count > 1 else { return nil }
            return LiveTrainSegment(tripId: trip.tripId, name: name, runNumber: runNumber, from: segment.from.name, to: segment.to.name,
                                    departure: segment.departure, arrival: segment.arrival, track: TrackPath(points),
                                    isLongDistance: liveLongDistanceModes.contains(segment.mode))
        }
    }
}
