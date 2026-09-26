import Foundation

public enum DBShareError: Error, Sendable, Equatable, LocalizedError {
    /// The shared content isn't a DB Navigator / bahn.de connection at all.
    case notAConnection
    /// It is one, but neither bahn.de nor the text itself gave enough to go on.
    case unreadable
    /// The connection is understood, but the app's own timetable data has no matching journey.
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notAConnection: "Das ist keine Verbindung aus dem DB Navigator oder von bahn.de."
        case .unreadable: "Die geteilte Verbindung konnte nicht geladen werden. Bitte versuch es später noch mal."
        case .notFound: "Diese Verbindung wurde in den Fahrplandaten nicht gefunden."
        }
    }
}

/// Finds the journey a shared DB connection (see `DBShare`) describes in the app's own timetable
/// data, so it gets live updates, alternatives and everything else a searched journey has.
public struct DBShareImporter: Sendable {
    let provider: CombinedProvider
    let bahnDe: BahnDeClient
    /// How far a planned time may differ from the shared one and still count as the same.
    static let tolerance: TimeInterval = 60

    public init(provider: CombinedProvider, bahnDe: BahnDeClient = BahnDeClient()) {
        self.provider = provider
        self.bahnDe = bahnDe
    }

    public func journey(fromShared text: String) async throws -> Journey {
        let vbid = DBShare.vbid(in: text)
        let textConnection = DBShare.connection(fromText: text)
        guard vbid != nil || textConnection != nil else { throw DBShareError.notAConnection }

        var connection: SharedConnection?
        if let vbid { connection = try? await bahnDe.sharedConnection(vbid: vbid) }
        guard let found = connection ?? textConnection else { throw DBShareError.unreadable }
        let shared = await locatingStations(of: found)

        if let journey = try? await searched(shared) { return journey }
        if !shared.legs.isEmpty, let journey = try? await rebuilt(shared) { return journey }
        throw DBShareError.notFound
    }

    // MARK: - Search

    /// A regular search from start to end, picking the result that runs at exactly the shared times.
    private func searched(_ shared: SharedConnection) async throws -> Journey? {
        let page = try await provider.journeys(JourneyQuery(from: shared.origin, to: shared.destination,
                                                            date: shared.departure.addingTimeInterval(-Self.tolerance)))
        let fitting = page.journeys.filter { Self.fits($0, shared) }
        // With only start and end known, prefer the result that also rides the named trains.
        return fitting.first { Self.ridesNamedTrains($0, shared) } ?? fitting.first
    }

    static func fits(_ journey: Journey, _ shared: SharedConnection) -> Bool {
        let transit = journey.transitLegs
        guard let first = transit.first, let last = transit.last,
              same(first.departure.planned, shared.departure) else { return false }
        if let arrival = shared.arrival, !same(last.arrival.planned, arrival) { return false }
        guard !shared.legs.isEmpty else { return true }
        return transit.count == shared.legs.count && zip(transit, shared.legs).allSatisfy { leg, sharedLeg in
            same(leg.departure.planned, sharedLeg.departure) && same(leg.arrival.planned, sharedLeg.arrival)
        }
    }

    static func ridesNamedTrains(_ journey: Journey, _ shared: SharedConnection) -> Bool {
        let transit = journey.transitLegs
        if let name = shared.firstTrain, !matches(name, transit.first?.line) { return false }
        if let name = shared.lastTrain, !matches(name, transit.last?.line) { return false }
        return true
    }

    // MARK: - Leg by leg

    /// Looks up every shared train on its own – for when the search prefers other routes (or splits
    /// a ride differently) and never returns the shared one.
    private func rebuilt(_ shared: SharedConnection) async throws -> Journey? {
        var legs: [Leg] = []
        for sharedLeg in shared.legs {
            guard let leg = try await leg(for: sharedLeg) else { return nil }
            legs.append(leg)
        }
        guard let first = legs.first else { return nil }
        return Journey(legs: legs, source: first.source)
    }

    private func leg(for shared: SharedConnection.Leg) async throws -> Leg? {
        let entries = try await provider.departures(at: shared.origin, date: shared.departure.addingTimeInterval(-2 * 60),
                                                    duration: 5)
        let candidates = entries
            .filter { Self.same($0.time.planned, shared.departure) }
            .sorted { Self.matches(shared.trainName, $0.line) && !Self.matches(shared.trainName, $1.line) }
        for entry in candidates {
            guard let trip = try? await provider.trip(id: entry.tripId, source: entry.source),
                  let start = trip.stopovers.firstIndex(where: {
                      $0.departure.map { Self.same($0.planned, shared.departure) } ?? false
                          && ($0.station.isSamePlace(as: shared.origin) || $0.station.isSamePlace(as: entry.station))
                  })
            else { continue }
            let rest = trip.stopovers[(start + 1)...]
            let end = rest.firstIndex { $0.station.isSamePlace(as: shared.destination) }
                ?? rest.firstIndex { stop in
                    // Feeds name some stations differently – the planned arrival nearby is just as telling.
                    guard let arrival = stop.arrival, Self.same(arrival.planned, shared.arrival) else { return false }
                    guard let a = stop.station.coordinate, let b = shared.destination.coordinate else { return true }
                    return a.distance(to: b) < 2_000
                }
            if let end, let leg = trip.leg(fromIndex: start, toIndex: end) { return leg }
        }
        return nil
    }

    // MARK: - Helpers

    /// Stations from the share's text are known by name only; looking them up first gives the
    /// routing (and the station matching above) coordinates to work with. bahn.de's own search is
    /// asked first: the names are DB's, and elsewhere a bare "Schaffhausen" can just as well be a
    /// village in Bavaria as the Swiss station.
    private func locatingStations(of shared: SharedConnection) async -> SharedConnection {
        var cache: [String: Station] = [:]
        func located(_ station: Station) async -> Station {
            guard station.coordinate == nil, station.evaNumber == nil else { return station }
            if let known = cache[station.name] { return known }
            let target = Station.normalize(station.name)
            func exact(_ results: [Station]) -> Station? {
                results.first { Station.normalize($0.name) == target || Station.normalize($0.displayName) == target }
            }
            let fromDB = (try? await bahnDe.searchStations(station.name)) ?? []
            let results = exact(fromDB) == nil ? (try? await provider.searchStations(station.name)) ?? [] : []
            let found = exact(fromDB) ?? exact(results) ?? fromDB.first ?? results.first ?? station
            cache[station.name] = found
            return found
        }
        var result = shared
        result.origin = await located(shared.origin)
        result.destination = await located(shared.destination)
        for index in result.legs.indices {
            result.legs[index].origin = await located(result.legs[index].origin)
            result.legs[index].destination = await located(result.legs[index].destination)
        }
        return result
    }

    static func same(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) <= tolerance }

    /// "ICE 1502" matches that line; a bare "89687" (DB leaves the category off some regional
    /// trains) matches any of the line's numbers, including the run number behind "RE 8".
    static func matches(_ name: String, _ line: Line?) -> Bool {
        guard let line else { return false }
        if TrainRoutePlanner.matches(Line.normalize(name), line) { return true }
        guard let number = trailingNumber(name) else { return false }
        return [line.number, line.tripNumber, trailingNumber(line.name), line.alternateName.flatMap(trailingNumber)]
            .contains(number)
    }

    private static func trailingNumber(_ name: String) -> String? {
        guard let last = name.split(separator: " ").last, last.allSatisfy(\.isNumber) else { return nil }
        return String(last)
    }
}
