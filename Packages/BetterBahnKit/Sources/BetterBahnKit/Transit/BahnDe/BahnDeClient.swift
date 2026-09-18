import Foundation

/// Rolling stock of a train, e.g. "ICE 3neo" with Tz 8030 + 8005.
public struct TrainFormation: Codable, Sendable, Hashable {
    public struct Unit: Codable, Sendable, Hashable {
        /// Marketing name of the series, e.g. "ICE 4".
        public var model: String?
        /// Triebzug number, e.g. "9465".
        public var number: String?
    }

    public var units: [Unit]

    /// "ICE 3neo" or "ICE 3neo + ICE 4".
    public var modelSummary: String? {
        let models = units.compactMap(\.model)
        guard !models.isEmpty else { return nil }
        var unique: [String] = []
        for model in models where !unique.contains(model) { unique.append(model) }
        return unique.count == 1 && models.count > 1 ? "\(models.count)× \(unique[0])" : unique.joined(separator: " + ")
    }

    /// "Tz 8030 + 8005"
    public var unitSummary: String? {
        let numbers = units.compactMap(\.number)
        guard !numbers.isEmpty else { return nil }
        return "Tz " + numbers.joined(separator: " + ")
    }
}

/// Endpoints of bahn.de (station search and coach sequence).
public struct BahnDeClient: Sendable {
    public static let baseURL = URL(string: "https://www.bahn.de/web/api")!
    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient(timeout: 8)) {
        self.http = http
    }

    struct Location: Decodable {
        var extId: String?
        var name: String
        var lat: Double?
        var lon: Double?
        var type: String?
    }

    public func searchStations(_ query: String) async throws -> [Station] {
        let url = Self.baseURL.appending(path: "reiseloesung/orte").appending(queryItems: [
            .init(name: "suchbegriff", value: query),
            .init(name: "typ", value: "ALL"),
            .init(name: "limit", value: "10"),
        ])
        let locations = try await http.get(url, as: [Location].self)
        return locations.compactMap { location in
            guard location.type == "ST", let eva = location.extId else { return nil }
            let coordinate = location.lat.flatMap { lat in location.lon.map { Coordinate(latitude: lat, longitude: $0) } }
            return Station(id: eva, name: location.name, coordinate: coordinate, evaNumber: eva, source: .bahnDe)
        }
    }

    /// EVA number for a station from any source (nearest match by name).
    public func evaNumber(for station: Station) async throws -> String? {
        if let eva = station.evaNumber { return eva }
        let candidates = try await searchStations(station.name)
        // A big interchange's own search also lists its separate entrances/exits a few hundred
        // meters apart under their own EVA (e.g. Berlin Gesundbrunnen's search also returns
        // "Gesundbrunnen Bahnhof Badstr.", which has no Timetables ("IRIS") schedule of its own) -
        // nearest-by-distance alone can pick one of those over the actual station, so a name match
        // is tried first.
        let target = Station.normalize(station.displayName)
        if let exact = candidates.first(where: { Station.normalize($0.displayName) == target }) {
            return exact.evaNumber
        }
        if let coordinate = station.coordinate {
            let nearest = candidates
                .compactMap { c in c.coordinate.map { (c, $0.distance(to: coordinate)) } }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 < 1_500 { return nearest.0.evaNumber }
        }
        return candidates.first?.evaNumber
    }

    // MARK: Coach sequence

    struct SequenceResponse: Decodable {
        struct Group: Decodable {
            struct Vehicle: Decodable {
                struct VehicleType: Decodable { var category: String?; var constructionType: String? }
                var type: VehicleType
                var vehicleID: String?
            }
            var name: String
            var vehicles: [Vehicle]
        }
        var groups: [Group]
    }

    /// Formation of a DB long-distance train at its departure from `station`.
    public func formation(for leg: Leg) async throws -> TrainFormation? {
        guard let line = leg.line, let number = line.number,
              let category = line.name.split(separator: " ").first.map(String.init)?.uppercased(),
              ["ICE", "IC", "EC", "ECE"].contains(category) else { return nil }
        guard let eva = try await evaNumber(for: leg.origin) else { return nil }
        let planned = leg.departure.planned
        let url = Self.baseURL.appending(path: "reisebegleitung/wagenreihung/vehicle-sequence").appending(queryItems: [
            .init(name: "administrationId", value: "80"),
            .init(name: "category", value: category),
            .init(name: "date", value: planned.formatted(.iso8601.year().month().day())),
            .init(name: "evaNumber", value: eva),
            .init(name: "number", value: number),
            .init(name: "time", value: JSONDecoding.isoString(planned)),
        ])
        let response = try await http.get(url, as: SequenceResponse.self)
        let formation = Self.formation(from: response, category: category)
        return formation.units.isEmpty ? nil : formation
    }

    static func formation(from response: SequenceResponse, category: String) -> TrainFormation {
        var units: [TrainFormation.Unit] = []
        for group in response.groups {
            let types = group.vehicles.compactMap(\.type.constructionType)
            // Locomotive-only groups (e.g. the Vectron of an ICE L) have a vehicle ID as name.
            if group.vehicles.allSatisfy({ $0.type.category == "LOCOMOTIVE" }) { continue }
            let letters = group.name.prefix { $0.isLetter }
            let digits = group.name.dropFirst(letters.count)
            let number = !letters.isEmpty && !digits.isEmpty && digits.allSatisfy(\.isNumber)
                ? String(digits.drop { $0 == "0" }) : nil
            units.append(.init(model: model(constructionTypes: types, groupName: group.name, category: category), number: number))
        }
        return TrainFormation(units: units)
    }

    /// Maps DB construction types (e.g. "I4081", "I1412") to series names.
    static func model(constructionTypes: [String], groupName: String, category: String) -> String? {
        var classes = Set<String>()
        var hasTalgo = false
        for type in constructionTypes {
            guard let prefix = type.first else { continue }
            let digits = String(type.dropFirst())
            if prefix == "R", digits.hasPrefix("89") { hasTalgo = true }
            guard prefix == "I", digits.count == 4 else { continue }
            // "4080" → 408, "1412" → 412, "0812" → 812, "8010" → 801
            let first = digits.first!
            classes.insert(["0", "1", "2", "9"].contains(first) ? String(digits.dropFirst().prefix(3)) : String(digits.prefix(3)))
        }
        let map: [(Set<String>, String)] = [
            (["401", "801", "802", "803", "804"], "ICE 1"),
            (["402", "805", "806", "807", "808"], "ICE 2"),
            (["403"], "ICE 3"),
            (["406"], "ICE 3M"),
            (["407"], "ICE 3 (BR 407)"),
            (["408"], "ICE 3neo"),
            (["411", "415"], "ICE T"),
            (["412", "812", "813"], "ICE 4"),
        ]
        for (set, name) in map where !set.isDisjoint(with: classes) { return name }
        if hasTalgo { return "ICE L" }
        if category == "IC" || category == "EC" {
            if groupName.hasPrefix("ICD") { return "IC 2 (Twindexx)" }
            if constructionTypes.contains(where: { $0.contains("4110") }) { return "IC 2 (KISS)" }
            return "IC 1"
        }
        return nil
    }
}
