import Foundation

/// The user's own train between two bahn.jetzt fixes: runs on along its track at the last speed,
/// stopping at the next stop it calls at, so the marker moves every second instead of jumping.
public struct LiveTrainMotion: Sendable {
    /// A fix further off the track than this is shown as it is (wrong or missing track).
    static let maxDistanceFromTrack: Double = 1_500

    public let track: TrackPath
    /// Meters along the track of each stop the train calls at, ascending.
    let stops: [Double]
    private(set) var fix: TrainPosition?
    /// Meters along the track of `fix`; nil while it isn't on the track.
    private(set) var fixMeters: Double?
    /// The last fix that moved, to work out the speed when bahn.jetzt sends none.
    private var lastMove: (meters: Double, time: Date)?
    private var estimatedSpeedKmh: Double?
    /// Fixes closer in time than this don't give a usable speed.
    static let minEstimateInterval: TimeInterval = 5
    static let maxSpeedKmh: Double = 330
    static let standingAfter: TimeInterval = 60

    /// bahn.jetzt's speed, else the one worked out from the last two fixes along the track.
    public var speedKmh: Double? { fix?.speedKmh ?? estimatedSpeedKmh }

    /// - Parameter stops: the stops the train calls at, in order.
    public init(track: [Coordinate], stops: [Coordinate]) {
        let path = TrackPath(track)
        self.track = path
        var last = 0.0
        self.stops = stops.compactMap { stop in
            guard let located = path.locate(stop, near: last), located.distance < 1_000 else { return nil }
            last = located.meters
            return located.meters
        }
    }

    public mutating func update(with fix: TrainPosition?) {
        self.fix = fix
        guard let fix, let located = track.locate(fix.coordinate, near: fixMeters),
              located.distance <= Self.maxDistanceFromTrack else {
            fixMeters = nil
            lastMove = nil
            estimatedSpeedKmh = nil
            return
        }
        fixMeters = located.meters
        // bahn.jetzt repeats a position until it has a new one: only a changed one tells the speed,
        // and one that stays put for a minute means the train stands.
        if let lastMove, abs(located.meters - lastMove.meters) < 1 {
            if fix.time.timeIntervalSince(lastMove.time) > Self.standingAfter { estimatedSpeedKmh = 0 }
            return
        }
        if let lastMove, case let elapsed = fix.time.timeIntervalSince(lastMove.time), elapsed >= Self.minEstimateInterval {
            estimatedSpeedKmh = min(Self.maxSpeedKmh, max(0, (located.meters - lastMove.meters) / elapsed * 3.6))
        }
        lastMove = (located.meters, fix.time)
    }

    /// Where the train is at `date`; nil without a fix.
    public func coordinate(at date: Date) -> Coordinate? {
        guard let fix else { return nil }
        guard let fixMeters else { return fix.coordinate }
        // An estimated speed runs from when the train was last seen moving, not from the repeated fix.
        let since = fix.speedKmh == nil ? lastMove?.time ?? fix.time : fix.time
        let elapsed = min(max(0, date.timeIntervalSince(since)), LiveTrainField.maxExtrapolation)
        let speed = max(0, speedKmh ?? 0) / 3.6
        // A train standing at (or just about to reach) a stop waits there.
        let nextStop = stops.first { $0 > fixMeters + 30 } ?? track.length
        let meters = min(nextStop, fixMeters + speed * elapsed)
        return track.coordinate(at: meters)
    }
}

/// Takes the jump out of a marker when new data moves it: the gap to where it was shown closes over
/// a few seconds instead of at once.
public struct LiveTrainSmoother: Sendable {
    public static let blendDuration: TimeInterval = 3
    /// Gaps larger than this are jumped (another train, or the app was away for a while).
    static let maxBlendDistance: Double = 5_000

    struct Offset: Sendable {
        var latitude: Double
        var longitude: Double
        var start: Date
    }

    private var shown: [String: Coordinate] = [:]
    private var offsets: [String: Offset] = [:]

    public init() {}

    /// The coordinates to draw for `raw` at `now`.
    /// - Parameter dataChanged: whether `raw` comes from new data since the last call; only then can it jump.
    public mutating func positions(_ raw: [String: Coordinate], dataChanged: Bool, at now: Date) -> [String: Coordinate] {
        if dataChanged {
            var fresh: [String: Offset] = [:]
            for (id, coordinate) in raw {
                guard let previous = shown[id] else { continue }
                // Where the running blend had the marker counts, not just the raw position before.
                let distance = previous.distance(to: coordinate)
                guard distance > 1, distance < Self.maxBlendDistance else { continue }
                fresh[id] = Offset(latitude: previous.latitude - coordinate.latitude,
                                   longitude: previous.longitude - coordinate.longitude, start: now)
            }
            offsets = fresh
        }
        var result: [String: Coordinate] = [:]
        for (id, coordinate) in raw {
            if let offset = offsets[id] {
                let left = 1 - now.timeIntervalSince(offset.start) / Self.blendDuration
                if left > 0 {
                    result[id] = Coordinate(latitude: coordinate.latitude + offset.latitude * left,
                                            longitude: coordinate.longitude + offset.longitude * left)
                    continue
                }
                offsets[id] = nil
            }
            result[id] = coordinate
        }
        shown = result
        return result
    }
}
