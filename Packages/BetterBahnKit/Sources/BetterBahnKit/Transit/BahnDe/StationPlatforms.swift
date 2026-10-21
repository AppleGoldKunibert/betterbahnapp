import Foundation

/// A DB station's platforms (#383): which tracks share one, and where along each track's platform the
/// stairs, lifts and, at a terminus, the exit are. From `Resources/Platforms.json`, which
/// `scripts/make-platforms.py` builds from DB InfraGO's OpenStation and OpenStreetMap (ODbL).
public struct StationPlatforms: Sendable, Hashable {
    /// A way off the platform.
    public struct Access: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            /// Stairs or an escalator.
            case stairs = "s"
            case lift = "l"
            /// The end of a terminus platform, where it meets the station hall.
            case exit = "x"
        }

        public var kind: Kind
        /// Metres along the platform edge from its `start`.
        public var position: Double

        public init(kind: Kind, position: Double) {
            self.kind = kind
            self.position = position
        }
    }

    /// A sector sign ("C") on the platform.
    public struct SectorSign: Sendable, Hashable {
        public var name: String
        /// Metres along the platform edge from its `start`.
        public var position: Double

        public init(name: String, position: Double) {
            self.name = name
            self.position = position
        }
    }

    /// One track's platform edge, as OpenStreetMap draws it.
    public struct Track: Sendable, Hashable {
        public var start: Coordinate
        public var end: Coordinate
        /// Metres from `start` to `end` along the edge.
        public var length: Double
        public var accesses: [Access]
        public var sectorSigns: [SectorSign]

        public init(start: Coordinate, end: Coordinate, length: Double, accesses: [Access], sectorSigns: [SectorSign] = []) {
            self.start = start
            self.end = end
            self.length = length
            self.accesses = accesses
            self.sectorSigns = sectorSigns
        }
    }

    /// Tracks sharing one platform, e.g. `["11", "12"]`.
    public var sharedPlatforms: [[String]]
    /// By track ("11").
    public var tracks: [String: Track]

    public init(sharedPlatforms: [[String]] = [], tracks: [String: Track] = [:]) {
        self.sharedPlatforms = sharedPlatforms
        self.tracks = tracks
    }

    /// Whether trains on these tracks stop at the same platform: the same track, or the other side of it.
    public func sharePlatform(_ first: String, _ second: String) -> Bool {
        guard !Self.sameTrack(first, second) else { return true }
        let a = Self.trackKeys(first), b = Self.trackKeys(second)
        return sharedPlatforms.contains { group in a.contains(where: group.contains) && b.contains(where: group.contains) }
    }

    /// By its name as the feeds or bahn.de write it: "3a/b" is "3a/b", else "3a", else "3".
    public func track(_ name: String) -> Track? {
        Self.trackKeys(name).lazy.compactMap { tracks[$0] }.first
    }

    /// The names a track goes by, from the most specific: "Gleis 3a/b" is "3a/b", "3a" and "3".
    static func trackKeys(_ name: String) -> [String] {
        let key = trackKey(name)
        var keys = [key]
        if let first = key.split(separator: "/").first.map(String.init), !keys.contains(first) { keys.append(first) }
        let number = String(key.prefix(while: \.isNumber))
        if !number.isEmpty, !keys.contains(number) { keys.append(number) }
        return keys
    }

    /// Sections of one track ("3a", "3b", "3a/b") are the same track.
    static func sameTrack(_ first: String, _ second: String) -> Bool {
        trackKeys(first).last == trackKeys(second).last
    }

    /// "Gleis 11" and "11 " are "11", as in the script.
    static func trackKey(_ name: String) -> String {
        var key = name.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["gleis", "gl."] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
        }
        return key.filter { !$0.isWhitespace }
    }

    /// The station with this EVA number; nil when there's nothing known about its platforms.
    public static func at(eva: String) -> StationPlatforms? {
        all[eva]
    }

    static let all: [String: StationPlatforms] = {
        guard let url = Bundle.module.url(forResource: "Platforms", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return parse(data)
    }()

    static func parse(_ data: Data) -> [String: StationPlatforms] {
        guard let file = try? JSONDecoder().decode([String: StationFile].self, from: data) else { return [:] }
        return file.mapValues { station in
            StationPlatforms(sharedPlatforms: station.p ?? [], tracks: (station.t ?? [:]).compactMapValues(\.track))
        }
    }

    private struct StationFile: Decodable {
        var p: [[String]]?
        var t: [String: TrackRow]?
    }

    /// `[lat, lon, lat, lon, length, [[kind, m], …], [[sector, m], …]]`
    private struct TrackRow: Decodable {
        var track: Track?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let values = try (0..<5).map { _ in try c.decode(Double.self) }
            let accesses = try c.decode([Pair].self).compactMap { pair in
                Access.Kind(rawValue: pair.name).map { Access(kind: $0, position: pair.position) }
            }
            let signs = try c.decode([Pair].self).map { SectorSign(name: $0.name, position: $0.position) }
            track = Track(start: Coordinate(latitude: values[0], longitude: values[1]),
                          end: Coordinate(latitude: values[2], longitude: values[3]),
                          length: values[4], accesses: accesses, sectorSigns: signs)
        }
    }

    /// `["s", 120]`
    private struct Pair: Decodable {
        var name: String
        var position: Double

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            name = try c.decode(String.self)
            position = try c.decode(Double.self)
        }
    }
}
