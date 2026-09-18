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
        if let shape = try? await shapeFromRouting(leg), Self.followsTracks(shape) { return shape }
        // Stops are only worth using when there are enough of them to trace the route.
        let stops = leg.stopovers.compactMap(\.station.coordinate)
        if Self.followsTracks(stops) { return stops }
        // Nothing track-shaped to be had: leaving the leg off the map beats drawing a line straight
        // across country, which is what every remaining candidate would amount to here.
        return nil
    }

    /// Asks for a connection between the two stations around that time and takes its track
    /// geometry. Slower than looking the trip up directly, and used only when that failed — but it
    /// comes back with real rails, which is the whole point.
    private func shapeFromRouting(_ leg: Leg) async throws -> [Coordinate]? {
        let page = try await transitous.journeys(
            JourneyQuery(from: leg.origin, to: leg.destination,
                         date: leg.departure.planned.addingTimeInterval(-10 * 60)))
        // The same train, if the routing happened to find it.
        let wanted = Line.normalize(leg.line?.name ?? "")
        if !wanted.isEmpty {
            for journey in page.journeys {
                for candidate in journey.transitLegs where Line.normalize(candidate.line?.name ?? "") == wanted {
                    if let shape = candidate.geometry, Self.followsTracks(shape) { return shape }
                }
            }
        }
        // Otherwise the most direct rail connection between the two: another train on the same
        // rails is an approximation, but it's the route a train actually takes.
        let railOnly = page.journeys.filter { journey in
            !journey.transitLegs.isEmpty && journey.transitLegs.allSatisfy { $0.line?.product.isTrain ?? false }
        }
        guard let best = railOnly.min(by: { $0.transitLegs.count < $1.transitLegs.count }) else { return nil }
        return best.transitLegs.compactMap(\.geometry).flatMap { $0 }
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
