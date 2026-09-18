import Foundation

/// Finds the real track geometry of a leg (OSM-based shapes from Transitous) instead of a straight line.
public struct RouteGeometryService: Sendable {
    let transitous: TransitousProvider
    let http: HTTPClient

    public init(transitous: TransitousProvider = TransitousProvider(), http: HTTPClient = HTTPClient(timeout: 20)) {
        self.transitous = transitous
        self.http = http
    }

    /// Whether a shape actually follows the tracks instead of cutting across country.
    ///
    /// Some sources hand out a leg as two points — the two stations — which draws a ruler-straight
    /// line across the map. A real track shape has far more detail than one point per 5 km, so
    /// anything coarser is treated as "no geometry" and looked up properly instead.
    public static func followsTracks(_ coordinates: [Coordinate]) -> Bool {
        guard coordinates.count > 1 else { return false }
        return Double(coordinates.count - 1) >= Polyline.length(coordinates) / 5_000
    }

    public func geometry(for leg: Leg) async -> [Coordinate]? {
        if let geometry = leg.geometry, Self.followsTracks(geometry) { return geometry }
        guard !leg.isWalking else { return nil }
        if let shape = try? await shapeFromTransitous(leg), Self.followsTracks(shape) { return shape }
        // Fallback: follow the stops instead of a straight line.
        let stops = leg.stopovers.compactMap(\.station.coordinate)
        if Self.followsTracks(stops) { return stops }
        // Nothing track-shaped to be had. Use the most detailed thing we have, but never a bare
        // straight line between two cities — leaving the leg off the map beats drawing a fiction.
        let candidates = [leg.geometry ?? [], stops].filter { $0.count > 2 }
        return candidates.max { $0.count < $1.count }
    }

    private func shapeFromTransitous(_ leg: Leg) async throws -> [Coordinate]? {
        var tripId: String? = leg.source == .transitous ? leg.tripId : nil
        if tripId == nil, let line = leg.line {
            // Find the same train in Transitous by line name/number around the planned departure.
            let entries = try await transitous.board(.departures, at: leg.origin,
                                                     date: leg.departure.planned.addingTimeInterval(-5 * 60), duration: 15,
                                                     products: Set(Product.allCases))
            let wanted = Line.normalize(line.name)
            tripId = entries.first { entry in
                abs(entry.time.planned.timeIntervalSince(leg.departure.planned)) <= 3 * 60
                    && (Line.normalize(entry.line.name) == wanted
                        || (line.number != nil && entry.line.number == line.number))
            }?.tripId
        }
        guard let tripId else { return nil }
        let itinerary = try await http.get(
            transitous.baseURL.appending(path: "v5/trip").appending(queryItems: [.init(name: "tripId", value: tripId)]),
            as: MItinerary.self, headers: ["User-Agent": HTTPClient.identifyingUserAgent])
        guard let shape = itinerary.legs.first(where: { !$0.isWalking })?.geometry, shape.count > 1 else { return nil }
        let start = leg.origin.coordinate ?? leg.stopovers.first?.station.coordinate
        let end = leg.destination.coordinate ?? leg.stopovers.last?.station.coordinate
        guard let start, let end else { return shape }
        return Polyline.slice(shape, from: start, to: end)
    }
}
