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

    public var id: Int
    public var checkin: Checkin
    public var createdAt: Date?

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

    /// One page (newest first, 15 per page) of the user's statuses and whether more pages exist.
    func statuses(username: String, page: Int) async throws -> (statuses: [TraewellingStatus], hasMore: Bool) {
        let result = try await authorized("user/\(username)/statuses", query: [.init(name: "page", value: String(page))],
                                          as: StatusPage.self)
        return (result.data, result.links?.next != nil)
    }

    /// A check-in imported for the travel map.
    struct HistoryTrip: Sendable {
        public var statusID: Int
        public var journey: Journey
    }

    /// One page of the check-in history, converted for the map.
    struct HistoryPage: Sendable {
        /// The page's check-ins not in `knownIDs` (or whose ride changed, see `refreshing`), with their track geometry.
        public var trips: [HistoryTrip]
        /// Every check-in on the page, so a full resync can tell which were deleted on Träwelling.
        public var statusIDs: [Int]
        /// The page had a check-in from `knownIDs`, so everything older was imported before
        /// (unless an earlier import stopped half way).
        public var reachedKnown: Bool
        public var hasMore: Bool
    }

    /// Waits before retrying a request Träwelling rejected with 429. Its API allows about 60 requests
    /// a minute, which a long history (one request per 15 check-ins plus their geometry) exceeds.
    static let rateLimitDelays: [Duration] = [.seconds(15), .seconds(30), .seconds(60)]

    /// Loads one page of the user's statuses and the geometry of the new ones, waiting and retrying
    /// when Träwelling rate-limits instead of giving up (#170). A known check-in in `refreshing` comes
    /// back too when its ride no longer matches the one imported: an edit on Träwelling (e.g. checking
    /// out at another stop) keeps the status ID.
    func historyPage(username: String, page: Int, knownIDs: Set<Int>, refreshing: [Int: Journey] = [:],
                     rateLimitDelays: [Duration] = TraewellingClient.rateLimitDelays) async throws -> HistoryPage {
        let result = try await retryingWhenRateLimited(delays: rateLimitDelays) {
            try await self.statuses(username: username, page: page)
        }
        let new = result.statuses.filter { status in
            guard knownIDs.contains(status.id) else { return true }
            return refreshing[status.id].map { Self.rideChanged($0, status) } ?? false
        }
        var geometries: [Int: [Coordinate]] = [:]
        if !new.isEmpty {
            // Without geometry the trip still shows (as a straight line until the map looks the track up).
            geometries = (try? await retryingWhenRateLimited(delays: rateLimitDelays) {
                try await self.polylines(statusIDs: new.map(\.id))
            }) ?? [:]
        }
        let trips = new.compactMap { status in
            status.journey(geometry: geometries[status.id]).map { HistoryTrip(statusID: status.id, journey: $0) }
        }
        return HistoryPage(trips: trips, statusIDs: result.statuses.map(\.id),
                           reachedKnown: result.statuses.contains { knownIDs.contains($0.id) }, hasMore: result.hasMore)
    }

    /// Whether a status no longer describes the ride imported for it: stops or planned times changed.
    static func rideChanged(_ imported: Journey, _ status: TraewellingStatus) -> Bool {
        guard let fresh = status.journey(geometry: nil)?.legs.first, let old = imported.legs.first else { return false }
        return fresh.origin.id != old.origin.id || fresh.destination.id != old.destination.id
            || fresh.departure != old.departure || fresh.arrival != old.arrival
    }

    private func retryingWhenRateLimited<T: Sendable>(delays: [Duration], _ operation: () async throws -> T) async throws -> T {
        var remaining = delays[...]
        while true {
            do {
                return try await operation()
            } catch TransitError.rateLimited {
                guard let delay = remaining.popFirst() else { throw TransitError.rateLimited }
                try await Task.sleep(for: delay)
            }
        }
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
