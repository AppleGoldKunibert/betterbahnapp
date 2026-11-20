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
        case .notAConnection: String(kit: "Das ist keine Verbindung aus dem DB Navigator oder von bahn.de.")
        case .unreadable: String(kit: "Die geteilte Verbindung konnte nicht geladen werden. Bitte versuch es später noch mal.")
        case .notFound: String(kit: "Diese Verbindung wurde in den Fahrplandaten nicht gefunden.")
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
        return try await journey(from: found)
    }

    /// Finds a connection known from elsewhere (e.g. a ticket's booked trains, see `DBTicket`).
    public func journey(from connection: SharedConnection) async throws -> Journey {
        let shared = await locatingStations(of: connection)

        if let journey = try? await searched(shared) { return journey }
        if !shared.legs.isEmpty {
            do {
                if let journey = try await rebuilt(shared) { return journey }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // No answer at all (offline, a server down): worth trying again rather than "not found".
                throw DBShareError.unreadable
            }
        }
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
    /// a ride differently) and never returns the shared one. A train the timetable data lacks (e.g. on the
    /// first days of a new timetable year, which DELFI publishes late) comes from bahn.de's own timetable,
    /// or else just as the share describes it, so the journey can still be saved.
    private func rebuilt(_ shared: SharedConnection) async throws -> Journey? {
        var legs: [Leg] = []
        for sharedLeg in shared.legs {
            if let leg = try await Self.unlessUnknown({ try await self.leg(for: sharedLeg) }) {
                legs.append(leg)
            } else if let leg = try await Self.unlessUnknown({ try await bahnDe.sharedLeg(sharedLeg) }) {
                legs.append(leg)
            } else if let leg = Self.plainLeg(sharedLeg) {
                legs.append(leg)
            } else {
                return nil
            }
        }
        guard let first = legs.first else { return nil }
        return Journey(legs: legs, source: first.source)
    }

    /// `work`'s answer, or nil when it failed because the train or station isn't known there. Getting no answer
    /// at all (offline, a timeout, a server down or blocking, the import cancelled) is thrown instead: a train
    /// the timetable data does know mustn't be saved in a poorer version just because it didn't answer in time.
    static func unlessUnknown<T>(_ work: () async throws -> T?) async throws -> T? {
        do {
            return try await work()
        } catch where isUnavailable(error) {
            throw error
        } catch {
            return nil
        }
    }

    static func isUnavailable(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError { return true }
        guard let error = error as? TransitError else { return false }
        switch error {
        case .timeout, .rateLimited, .unauthorized: return true
        case .http(let status, _): return error.isBlocked || status == 401 || status == 429 || status >= 500
        case .decoding, .notFound, .invalidInput: return false
        }
    }

    /// `shared` with just what the share says: its two ends and planned times. Only for stations that
    /// were found (coordinates), so a misread name doesn't end up in a saved journey.
    static func plainLeg(_ shared: SharedConnection.Leg) -> Leg? {
        guard shared.origin.coordinate != nil, shared.destination.coordinate != nil,
              shared.departure < shared.arrival else { return nil }
        return Leg(origin: shared.origin, destination: shared.destination,
                   departure: TimeInfo(planned: shared.departure, actual: nil),
                   arrival: TimeInfo(planned: shared.arrival, actual: nil),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: nil, line: line(named: shared.trainName),
                   direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    /// A line for a train known only by DB's name for it ("RJ 179", "R 1059", a bare "89687"), of the
    /// product bahn.de's `produktGattung` gives, else the one its category stands for.
    static func line(named name: String, gattung: String? = nil) -> Line {
        let category = String(name.prefix { $0.isLetter }).uppercased()
        let number = name.split(separator: " ").last.map(String.init).flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
        var product: Product
        switch category {
        case "ICE", "ICD", "ECE", "RJ", "RJX", "TGV", "FR", "EST": product = .highSpeed
        case "NJ", "EN": product = .nightTrain
        case "IR", "FLX": product = .interregio
        case "IC", "EC", "D": product = .longDistance
        case "RE", "IRE", "REX": product = .regionalExpress
        case "S": product = .suburban
        default: product = .regional
        }
        // bahn.de's own class wins, except where it is coarser ("REGIONAL" for an RE, "EC_IC" for a Nightjet).
        let fromGattung = BahnDeClient.product(forGattung: gattung)
        if ![.nightTrain, .interregio, .regionalExpress].contains(product), fromGattung != .other {
            product = fromGattung
        }
        return Line(name: name, number: number, product: product, operatorName: nil)
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
            guard station.coordinate == nil else { return station }
            if let known = cache[station.name] { return known }
            let fromDB = (try? await bahnDe.searchStations(station.name)) ?? []
            // Known by EVA number (e.g. from a ticket): only the coordinates are missing.
            if let eva = station.evaNumber {
                let found = fromDB.first { $0.evaNumber == eva } ?? station
                cache[station.name] = found
                return found
            }
            let target = Station.normalize(station.name)
            func exact(_ results: [Station]) -> Station? {
                results.first { Station.normalize($0.name) == target || Station.normalize($0.displayName) == target }
            }
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
        // A coupled train's number too: a seat reserved in ICE 940 is in the ICE 950 it runs with.
        return ([line.number, line.tripNumber] + line.allNames.map(trailingNumber)).contains(number)
    }

    private static func trailingNumber(_ name: String) -> String? {
        guard let last = name.split(separator: " ").last, last.allSatisfy(\.isNumber) else { return nil }
        return String(last)
    }
}
