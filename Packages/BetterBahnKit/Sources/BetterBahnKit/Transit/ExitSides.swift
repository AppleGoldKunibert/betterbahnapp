import Foundation

/// The side of the train the platform is on where the user gets off (#394): "Ausstieg in Fahrtrichtung links".
public enum ExitSide: String, Codable, Sendable, Hashable {
    case left
    case right

    /// "Ausstieg in Fahrtrichtung links"
    public var displayName: String { "Ausstieg in Fahrtrichtung \(german)" }
    /// "Ausstieg links", where space is short (the reminder).
    public var shortName: String { "Ausstieg \(german)" }

    var german: String { self == .left ? "links" : "rechts" }
    var opposite: ExitSide { self == .left ? .right : .left }
}

/// Which side of the track each platform is on, from the offline list `Resources/ExitSides.json` built by
/// `scripts/make-exit-sides.py` from OpenStreetMap (© OpenStreetMap contributors, ODbL) (#394), corrected
/// by hand in `Resources/ExitSideOverrides.json` (same format; its tracks replace the generated ones).
///
/// A platform's side is given for a train on a compass heading; a train the other way has it on its other
/// side. So the side where the user gets off needs the direction the train arrives in: along the route's
/// geometry, else from the previous stop. A dead-end track (`terminal`) is always entered on its heading.
/// Nothing is shown when the list doesn't know the track or the direction isn't clear, and nothing for
/// U-Bahn, tram and bus legs: their platforms aren't in the list, and "2 (U5)" would pass as track 2.
public enum ExitSides {
    public struct Track: Codable, Sendable, Hashable {
        /// The track number as the app compares it (`normalizedTrack`): "7", "4a", "101".
        public var track: String
        /// Compass heading (0 north, 90 east) of a train the side applies to.
        public var heading: Double
        public var side: ExitSide
        /// A buffer stop lies ahead on `heading`: trains arriving here always travel on it.
        public var terminal: Bool?

        public init(track: String, heading: Double, side: ExitSide, terminal: Bool? = nil) {
            self.track = track
            self.heading = heading
            self.side = side
            self.terminal = terminal
        }
    }

    public struct Entry: Codable, Sendable, Hashable {
        public var name: String
        /// DB's Ril100 code (OSM `railway:ref`), e.g. "FF".
        public var ril100: String?
        /// EVA number (OSM `uic_ref`), e.g. "8000105".
        public var uic: String?
        public var lat: Double
        public var lon: Double
        public var tracks: [Track]
        /// An S-Bahn or Stadtbahn station of its own (OSM `station=light_rail`): used for S-Bahn trains
        /// only, since a Stadtbahn stop next to a station can share its platform numbers.
        public var light: Bool?

        public init(name: String, ril100: String? = nil, uic: String? = nil, lat: Double, lon: Double, tracks: [Track],
                    light: Bool? = nil) {
            self.name = name
            self.ril100 = ril100
            self.uic = uic
            self.lat = lat
            self.lon = lon
            self.tracks = tracks
            self.light = light
        }

        var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
    }

    struct File: Decodable {
        var stations: [Entry]
    }

    static let all: [Entry] = merging(load("ExitSides"), overrides: load("ExitSideOverrides"))

    static func load(_ name: String) -> [Entry] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.stations
    }

    /// Loads the list off the calling thread (decoding it takes a moment).
    public static func preload() async {
        await Task.detached(priority: .utility) { _ = all }.value
    }

    /// The generated entries with the overrides put in: an override's track replaces that track at every entry
    /// of the same station (same code or EVA number, else the same name within a kilometre); a station the
    /// list doesn't have is added.
    static func merging(_ entries: [Entry], overrides: [Entry]) -> [Entry] {
        var result = entries
        for override in overrides {
            let indices = result.indices.filter { isSameStation(result[$0], override) }
            if indices.isEmpty {
                result.append(override)
                continue
            }
            for index in indices {
                for track in override.tracks {
                    result[index].tracks.removeAll { $0.track == track.track }
                    result[index].tracks.append(track)
                }
            }
        }
        return result
    }

    static func isSameStation(_ a: Entry, _ b: Entry) -> Bool {
        if let x = a.ril100, let y = b.ril100 { return x == y }
        if let x = a.uic, let y = b.uic, x == y { return true }
        return Station.normalize(a.name) == Station.normalize(b.name) && a.coordinate.distance(to: b.coordinate) < 1000
    }

    // MARK: - Lookup

    /// Where the user gets off `leg`: at its destination, on the arrival platform, arriving along the leg's
    /// geometry (else from the stop before).
    public static func side(leaving leg: Leg) -> ExitSide? {
        side(leaving: leg, in: all)
    }

    static func side(leaving leg: Leg, in entries: [Entry]) -> ExitSide? {
        // Trains only: the list has railway platforms, and "2 (U5)" at Berlin Hbf is the U-Bahn's, not DB's track 2.
        guard !leg.isWalking, leg.line?.product.isTrain == true, let stop = leg.destination.coordinate else { return nil }
        let previous = leg.stopovers.last { !$0.station.isSamePlace(as: leg.destination) }?.station ?? leg.origin
        let heading = arrivalHeading(at: stop, along: leg.geometry, from: previous.coordinate)
        return side(at: leg.destination, platform: leg.arrivalPlatform?.best, heading: heading, product: leg.line?.product, in: entries)
    }

    /// Where the user gets off `trip` at the stop at `index`.
    public static func side(leaving trip: Trip, at index: Int) -> ExitSide? {
        side(leaving: trip, at: index, in: all)
    }

    static func side(leaving trip: Trip, at index: Int, in entries: [Entry]) -> ExitSide? {
        guard trip.line?.product.isTrain == true, trip.stopovers.indices.contains(index), index > 0,
              let stop = trip.stopovers[index].station.coordinate else { return nil }
        let stopover = trip.stopovers[index]
        let heading = arrivalHeading(at: stop, along: trip.geometry, from: trip.stopovers[index - 1].station.coordinate)
        return side(at: stopover.station, platform: stopover.arrivalPlatform?.best ?? stopover.departurePlatform?.best,
                    heading: heading, product: trip.line?.product, in: entries)
    }

    /// The side at `station` for a train of `product` on `platform` arriving on `heading` (compass degrees;
    /// nil when unknown). nil when the list doesn't know the track, the platform has no number, or the
    /// heading is too far from the track's axis to tell (over 60° off both ways).
    public static func side(at station: Station, platform: String?, heading: Double?, product: Product?) -> ExitSide? {
        side(at: station, platform: platform, heading: heading, product: product, in: all)
    }

    static func side(at station: Station, platform: String?, heading: Double?, product: Product?, in entries: [Entry]) -> ExitSide? {
        guard let platform, let track = normalizedTrack(platform) else { return nil }
        for entry in candidates(for: station, product: product, in: entries) {
            guard let found = entry.tracks.first(where: { $0.track == track }) else { continue }
            if found.terminal == true { return found.side }
            guard let heading else { return nil }
            let difference = angle(heading, found.heading)
            if difference <= 60 { return found.side }
            if difference >= 120 { return found.side.opposite }
            return nil
        }
        return nil
    }

    /// The entries that are `station`, best first: by EVA number, then by Ril100 code, then by name – all
    /// within 1.5 km, so a neighbouring station's track with the same number is never taken. An S-Bahn or
    /// Stadtbahn station of its own (`light`) only for an S-Bahn train.
    static func candidates(for station: Station, product: Product?, in entries: [Entry]) -> [Entry] {
        guard let coordinate = station.coordinate else { return [] }
        let near = entries.filter {
            ($0.light != true || product == .suburban)
                && abs($0.lat - coordinate.latitude) < 0.015 && abs($0.lon - coordinate.longitude) < 0.025
                && $0.coordinate.distance(to: coordinate) < 1500
        }
        guard !near.isEmpty else { return [] }
        let code = near.contains { $0.ril100 != nil } ? Ril100.code(for: station) : nil
        let name = Station.normalize(station.name)
        func rank(_ entry: Entry) -> Int? {
            if let eva = station.evaNumber, entry.uic == eva { return 0 }
            if let code, entry.ril100 == code { return 1 }
            let entryName = Station.normalize(entry.name)
            if !name.isEmpty, !entryName.isEmpty, name.contains(entryName) || entryName.contains(name) { return 2 }
            return nil
        }
        return near.compactMap { entry in rank(entry).map { (entry: entry, rank: $0, distance: entry.coordinate.distance(to: coordinate)) } }
            .sorted { ($0.rank, $0.distance) < ($1.rank, $1.distance) }
            .map(\.entry)
    }

    // MARK: - Direction and numbers

    /// The compass heading a train arriving at `stop` travels on: along the route's `geometry` over the last
    /// 250 m before its point nearest the stop, else the bearing from the `previous` stop (which misleads on
    /// a curved approach, which is why `side(at:…)` wants it within 60° of the track's axis).
    public static func arrivalHeading(at stop: Coordinate, along geometry: [Coordinate]?, from previous: Coordinate?) -> Double? {
        if let geometry, geometry.count >= 2 {
            var nearest = 0
            var nearestDistance = Double.infinity
            for (index, point) in geometry.enumerated() {
                let distance = point.distance(to: stop)
                if distance < nearestDistance {
                    nearest = index
                    nearestDistance = distance
                }
            }
            if nearestDistance <= 500 {
                var back = nearest
                var walked = 0.0
                while back > 0, walked < 250 {
                    walked += geometry[back - 1].distance(to: geometry[back])
                    back -= 1
                }
                if walked >= 50 { return bearing(from: geometry[back], to: geometry[nearest]) }
            }
        }
        if let previous, previous.distance(to: stop) > 200 { return bearing(from: previous, to: stop) }
        return nil
    }

    /// The track number platforms are compared by: "7 D-G" -> "7", "Gleis 4a" -> "4a", "07" -> "7"; nil
    /// without a number. Mirrors `normalize_track` in `scripts/make-exit-sides.py`.
    static func normalizedTrack(_ text: String) -> String? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces).lowercased())
        for prefix in ["gleis", "gl.", "bahnsteig", "track", "platform", "voie", "perron"] where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count).drop { $0 == " " }
            break
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        rest = rest.dropFirst(digits.count)
        var letter = ""
        if let first = rest.first, first.isASCII, first.isLetter {
            // "7a" is a track, "7ab" is not a number we know.
            if let after = rest.dropFirst().first, after.isASCII, after.isLetter || after.isNumber { return nil }
            letter = String(first)
        }
        let number = digits.drop { $0 == "0" }
        return (number.isEmpty ? "0" : String(number)) + letter
    }

    /// The smaller angle between two headings, 0...180.
    static func angle(_ a: Double, _ b: Double) -> Double {
        let difference = abs((a - b).truncatingRemainder(dividingBy: 360))
        return difference > 180 ? 360 - difference : difference
    }

    /// Initial compass bearing from `a` to `b`.
    static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
