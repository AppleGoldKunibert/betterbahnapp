import Foundation

/// A past check-in from Träwelling, as needed for the travel map.
public struct TraewellingStatus: Decodable, Sendable, Hashable {
    public struct Checkin: Decodable, Sendable, Hashable {
        public struct Stop: Decodable, Sendable, Hashable {
            public struct StationInfo: Decodable, Sendable, Hashable {
                public var id: Int?
                public var name: String
                public var latitude: Double?
                public var longitude: Double?
            }
            public var name: String?
            public var station: StationInfo?
            public var departurePlanned: Date?
            public var departureReal: Date?
            public var departure: Date?
            public var arrivalPlanned: Date?
            public var arrivalReal: Date?
            public var arrival: Date?
        }
        public var trip: Int?
        /// The trip's HAFAS ID, needed to look its stopovers up again (e.g. to move the exit).
        public var hafasId: String?
        public var category: String?
        public var lineName: String?
        public var journeyNumber: Int?
        public var distance: Int?
        public var duration: Int?
        public var manualDeparture: Date?
        public var manualArrival: Date?
        public var origin: Stop
        public var destination: Stop
    }

    /// Who checked in (Träwelling's `LightUser`).
    public struct User: Decodable, Sendable, Hashable {
        public var id: Int
        public var displayName: String
        public var username: String
        public var profilePicture: URL? { profilePictureString.flatMap(URL.init(string:)) }
        private var profilePictureString: String?

        enum CodingKeys: String, CodingKey {
            case id, displayName, username, profilePictureString = "profilePicture"
        }
    }

    public var id: Int
    public var checkin: Checkin
    public var user: User? { userValue?.value }
    public var createdAt: Date?
    /// The check-in's text, which may hold Mastodon `:shortcode:` emojis (`CustomEmojiText`).
    public var body: String?
    public var visibility: TraewellingVisibility? { visibilityValue?.value.flatMap(TraewellingVisibility.init(rawValue:)) }
    public var business: TraewellingBusiness? { businessValue?.value.flatMap(TraewellingBusiness.init(rawValue:)) }
    // Read leniently: a value this app doesn't know must not break loading the whole history.
    private var visibilityValue: LenientInt?
    private var businessValue: LenientInt?
    private var userValue: LenientUser?

    enum CodingKeys: String, CodingKey {
        case id, checkin, createdAt, body
        case visibilityValue = "visibility", businessValue = "business", userValue = "user"
    }

    struct LenientInt: Decodable, Sendable, Hashable {
        var value: Int?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Int.self) }
    }

    struct LenientUser: Decodable, Sendable, Hashable {
        var value: User?
        init(from decoder: Decoder) throws { value = try? User(from: decoder) }
    }

    public var product: Product {
        switch checkin.category {
        case "nationalExpress": .highSpeed
        case "national": .longDistance
        case "regionalExp": .regionalExpress
        case "regional": .regional
        case "suburban": .suburban
        case "subway": .subway
        case "tram": .tram
        case "bus": .bus
        case "ferry": .ferry
        default: .other
        }
    }

    public var departure: Date? {
        checkin.manualDeparture ?? checkin.origin.departureReal ?? checkin.origin.departure ?? checkin.origin.departurePlanned
    }

    /// Converts the check-in into a one-leg journey with its track geometry.
    public func journey(geometry: [Coordinate]?) -> Journey? {
        func station(_ stop: Checkin.Stop) -> Station {
            let info = stop.station
            let coordinate = info?.latitude.flatMap { lat in info?.longitude.map { Coordinate(latitude: lat, longitude: $0) } }
            return Station(id: "trwl-\(info?.id ?? 0)", name: info?.name ?? stop.name ?? "?",
                           coordinate: coordinate, evaNumber: nil, source: .traewelling)
        }
        let o = checkin.origin, d = checkin.destination
        guard let plannedDeparture = o.departurePlanned ?? o.departure ?? checkin.manualDeparture,
              let plannedArrival = d.arrivalPlanned ?? d.arrival ?? checkin.manualArrival else { return nil }
        let name = checkin.lineName ?? "Fahrt"
        let line = Line(name: name, number: checkin.journeyNumber.map(String.init), product: product, operatorName: nil)
        let leg = Leg(
            origin: station(o), destination: station(d),
            departure: TimeInfo(planned: plannedDeparture, actual: checkin.manualDeparture ?? o.departureReal),
            arrival: TimeInfo(planned: plannedArrival, actual: checkin.manualArrival ?? d.arrivalReal),
            departurePlatform: nil, arrivalPlatform: nil, tripId: "trwl-status-\(id)", line: line, direction: nil,
            isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .traewelling, geometry: geometry
        )
        return Journey(legs: [leg], source: .traewelling)
    }
}

public extension TraewellingClient {
    struct StatusPage: Decodable, Sendable {
        struct Links: Decodable, Sendable { var next: String? }
        var data: [TraewellingStatus]
        var links: Links?
    }

    /// One page (newest first) of the user's statuses and whether more pages exist.
    func statuses(username: String, page: Int) async throws -> (statuses: [TraewellingStatus], hasMore: Bool) {
        let result = try await authorized("user/\(username)/statuses", query: [.init(name: "page", value: String(page))],
                                          as: StatusPage.self)
        return (result.data, result.links?.next != nil)
    }

    /// Track geometries for status IDs (Träwelling returns GeoJSON LineStrings, lon/lat order).
    func polylines(statusIDs: [Int]) async throws -> [Int: [Coordinate]] {
        struct Response: Decodable, Sendable {
            struct Collection: Decodable, Sendable {
                struct Feature: Decodable, Sendable {
                    struct Geometry: Decodable, Sendable { var coordinates: [[Double]] }
                    struct Properties: Decodable, Sendable { var statusId: Int? }
                    var geometry: Geometry
                    var properties: Properties?
                }
                var features: [Feature]
            }
            var data: Collection
        }
        guard !statusIDs.isEmpty else { return [:] }
        let ids = statusIDs.map(String.init).joined(separator: ",")
        let response = try await authorized("polyline/\(ids)", as: Response.self)
        var result: [Int: [Coordinate]] = [:]
        for feature in response.data.features {
            guard let id = feature.properties?.statusId else { continue }
            result[id] = feature.geometry.coordinates.compactMap { pair in
                pair.count >= 2 ? Coordinate(latitude: pair[1], longitude: pair[0]) : nil
            }
        }
        return result
    }
}
