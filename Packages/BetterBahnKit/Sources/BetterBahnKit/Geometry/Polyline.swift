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
    public static func slice(_ coordinates: [Coordinate], from start: Coordinate, to end: Coordinate) -> [Coordinate] {
        guard coordinates.count > 1 else { return coordinates }
        func nearest(_ target: Coordinate, after lower: Int = 0) -> Int {
            var best = lower, bestDistance = Double.infinity
            for i in lower..<coordinates.count {
                let d = coordinates[i].distance(to: target)
                if d < bestDistance { bestDistance = d; best = i }
            }
            return best
        }
        let a = nearest(start)
        let b = nearest(end, after: a)
        guard b > a else { return [start, end] }
        return Array(coordinates[a...b])
    }
}
