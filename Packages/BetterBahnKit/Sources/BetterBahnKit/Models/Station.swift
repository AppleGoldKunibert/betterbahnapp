import Foundation

/// Where a piece of data came from. Trip IDs and station IDs are only valid for their source.
public enum DataSource: String, Codable, Sendable, Hashable {
    /// Decode previously saved stations/journeys only; no active provider.
    case dbRest
    case bahnDe
    case transitous
    /// Imported check-ins from Träwelling.
    case traewelling
}

public struct Coordinate: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Distance in meters (haversine).
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

public struct Station: Codable, Sendable, Hashable, Identifiable {
    /// Provider-specific ID (EVA number for bahn.de, stop ID for Transitous).
    public var id: String
    public var name: String
    public var coordinate: Coordinate?
    /// DB EVA number / IBNR, if known. Used to match stations across sources.
    public var evaNumber: String?
    public var source: DataSource
    /// District/state, e.g. "Bernau am Chiemsee, Bayern" for a station whose own name is just
    /// "Bernau" – tells apart same-named stations in different parts of the country.
    public var region: String?

    public init(id: String, name: String, coordinate: Coordinate?, evaNumber: String?, source: DataSource, region: String? = nil) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.evaNumber = evaNumber
        self.source = source
        self.region = region
    }

    /// Loose equality across sources: same EVA, or same-ish name within 400 m.
    public func isSamePlace(as other: Station) -> Bool {
        if source == other.source, id == other.id { return true }
        if let a = evaNumber, let b = other.evaNumber { return a == b }
        if let a = coordinate, let b = other.coordinate, a.distance(to: b) < 400 { return true }
        return Station.normalize(name) == Station.normalize(other.name)
    }

    static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "hauptbahnhof", with: "hbf")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// User-facing name preferring DB's common short forms over the raw Hafas name,
    /// e.g. "S+U Berlin Hauptbahnhof" -> "Berlin Hbf", "S Spandau Bhf (Berlin)" -> "Berlin-Spandau".
    public var displayName: String { Station.displayName(for: name) }

    /// Stations in the "<city> <stop>" form (no hyphen) despite matching the "<stop> Bhf (<city>)" pattern.
    private static let unhyphenatedStops: Set<String> = [
        "südkreuz", "ostbahnhof", "ostkreuz", "gesundbrunnen", "hauptbahnhof",
        "potsdamer platz", "alexanderplatz", "friedrichstraße", "zoologischer garten",
        "lichtenberg", "schönefeld flughafen",
    ]

    static func displayName(for rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespaces)

        for prefix in ["S+U ", "S ", "U ", "Bus "] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }

        if name.hasSuffix(")"), let openParen = name.range(of: " (", options: .backwards) {
            let city = String(name[openParen.upperBound..<name.index(before: name.endIndex)])
            var stop = String(name[name.startIndex..<openParen.lowerBound])
            if stop.hasSuffix(" Bhf") {
                stop.removeLast(" Bhf".count)
            }
            name = unhyphenatedStops.contains(stop.lowercased()) ? "\(city) \(stop)" : "\(city)-\(stop)"
        }

        return name.replacingOccurrences(of: "Hauptbahnhof", with: "Hbf")
    }
}
