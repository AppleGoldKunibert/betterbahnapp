import Foundation

/// Google encoded polyline format (as used by MOTIS/Transitous, precision 6).
public enum Polyline {
    public static func decode(_ encoded: String, precision: Int = 6) -> [Coordinate] {
        let factor = pow(10.0, Double(precision))
        var coordinates: [Coordinate] = []
        var index = encoded.utf8.startIndex
        let bytes = encoded.utf8
        var lat = 0, lon = 0

        func next() -> Int? {
            var result = 0, shift = 0
            while index < bytes.endIndex {
                let byte = Int(bytes[index]) - 63
                index = bytes.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }

        while index < bytes.endIndex {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            coordinates.append(Coordinate(latitude: Double(lat) / factor, longitude: Double(lon) / factor))
        }
        return coordinates
    }

    public static func encode(_ coordinates: [Coordinate], precision: Int = 6) -> String {
        let factor = pow(10.0, Double(precision))
        var output = ""
        var lastLat = 0, lastLon = 0
        func append(_ value: Int) {
            var v = value < 0 ? ~(value << 1) : (value << 1)
            while v >= 0x20 {
                output.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1F)) + 63)))
                v >>= 5
            }
            output.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
        }
        for c in coordinates {
            let lat = Int((c.latitude * factor).rounded()), lon = Int((c.longitude * factor).rounded())
            append(lat - lastLat)
            append(lon - lastLon)
            lastLat = lat
            lastLon = lon
        }
        return output
    }

    /// Total length in meters.
    public static func length(_ coordinates: [Coordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// The part of `coordinates` between the points closest to `start` and `end`.
    ///
    /// Never invents geometry: if the shape doesn't cover the two ends (or covers them in the
    /// opposite direction and can't be turned around), the whole shape is returned rather than a
    /// straight line between them, which would cut across country instead of following the tracks.
    public static func slice(_ coordinates: [Coordinate], from start: Coordinate, to end: Coordinate) -> [Coordinate] {
        guard coordinates.count > 1 else { return coordinates }
        func nearest(_ target: Coordinate) -> (index: Int, distance: Double) {
            var best = 0, bestDistance = Double.infinity
            for i in coordinates.indices {
                let d = coordinates[i].distance(to: target)
                if d < bestDistance { bestDistance = d; best = i }
            }
            return (best, bestDistance)
        }
        let a = nearest(start), b = nearest(end)
        // The shape belongs to a different trip than the one we're slicing.
        guard a.distance < 5_000, b.distance < 5_000 else { return coordinates }
        if a.index == b.index { return coordinates }
        // Shapes are sometimes stored against the direction of travel.
        let part = Array(coordinates[min(a.index, b.index) ... max(a.index, b.index)])
        return a.index <= b.index ? part : part.reversed()
    }

    /// Drops points that lie within `tolerance` meters of the line they sit on (Douglas–Peucker).
    /// Keeps the shape while cutting the point count a map has to draw.
    public static func simplify(_ coordinates: [Coordinate], tolerance: Double = 10) -> [Coordinate] {
        guard coordinates.count > 2 else { return coordinates }
        var keep = [Bool](repeating: false, count: coordinates.count)
        keep[0] = true
        keep[coordinates.count - 1] = true
        var stack = [(0, coordinates.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first, maxDistance = 0.0
            for i in (first + 1) ..< last {
                let d = distance(from: coordinates[i], toSegment: coordinates[first], coordinates[last])
                if d > maxDistance { maxDistance = d; farthest = i }
            }
            guard maxDistance > tolerance else { continue }
            keep[farthest] = true
            stack.append((first, farthest))
            stack.append((farthest, last))
        }
        return coordinates.indices.filter { keep[$0] }.map { coordinates[$0] }
    }

    /// Distance in meters from a point to the segment `a`–`b`.
    static func distance(from point: Coordinate, toSegment a: Coordinate, _ b: Coordinate) -> Double {
        // Project in degrees (fine over a few hundred meters), then measure the real distance.
        let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return point.distance(to: a) }
        let t = max(0, min(1, ((point.longitude - a.longitude) * dx + (point.latitude - a.latitude) * dy) / squared))
        return point.distance(to: Coordinate(latitude: a.latitude + dy * t, longitude: a.longitude + dx * t))
    }
}
