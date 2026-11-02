import Foundation

/// A track as a line with distances along it, so a train can be placed on it by meters run rather
/// than by straight lines between two fixes (which would cut corners in curves).
public struct TrackPath: Sendable, Hashable {
    public let points: [Coordinate]
    /// Meters from the first point to each point; same count as `points`.
    let offsets: [Double]

    public init(_ points: [Coordinate]) {
        self.points = points
        var offsets = [0.0]
        offsets.reserveCapacity(points.count)
        for (a, b) in zip(points, points.dropFirst()) {
            offsets.append(offsets[offsets.count - 1] + a.distance(to: b))
        }
        self.offsets = points.isEmpty ? [] : offsets
    }

    public var length: Double { offsets.last ?? 0 }

    public var isEmpty: Bool { points.isEmpty }

    /// The point `meters` along the track, clamped to its ends; nil for an empty track.
    public func coordinate(at meters: Double) -> Coordinate? {
        guard let first = points.first else { return nil }
        guard points.count > 1, meters > 0 else { return first }
        guard meters < length else { return points[points.count - 1] }
        // First offset beyond `meters` (binary search: tracks have thousands of points).
        var low = 1, high = offsets.count - 1
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] <= meters { low = mid + 1 } else { high = mid }
        }
        let a = points[low - 1], b = points[low]
        let span = offsets[low] - offsets[low - 1]
        let t = span > 0 ? (meters - offsets[low - 1]) / span : 0
        return Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                          longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Where `point` lies on the track: meters along it and how far off the track it is.
    /// - Parameter near: meters along the track the point is expected close to; where the track passes
    ///   the same spot twice (a loop, there and back), the projection closest to it wins.
    public func locate(_ point: Coordinate, near: Double? = nil) -> (meters: Double, distance: Double)? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return (0, point.distance(to: first)) }
        let metersPerDegree = 111_320.0
        let cosLat = cos(point.latitude * .pi / 180)
        func project(_ c: Coordinate) -> (Double, Double) {
            ((c.longitude - point.longitude) * metersPerDegree * cosLat, (c.latitude - point.latitude) * metersPerDegree)
        }
        var best: (meters: Double, distance: Double, score: Double)?
        var previous = project(first)
        for index in 1 ..< points.count {
            let (ax, ay) = previous, (bx, by) = project(points[index])
            previous = (bx, by)
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(ax * dx + ay * dy) / lengthSquared)) : 0
            let x = ax + t * dx, y = ay + t * dy
            let distance = (x * x + y * y).squareRoot()
            let meters = offsets[index - 1] + t * (offsets[index] - offsets[index - 1])
            // Within a few hundred meters of the track, being close to the expected spot matters more.
            let score = distance + (near.map { abs(meters - $0) * 0.05 } ?? 0)
            if best == nil || score < best!.score { best = (meters, distance, score) }
        }
        return best.map { ($0.meters, $0.distance) }
    }
}
