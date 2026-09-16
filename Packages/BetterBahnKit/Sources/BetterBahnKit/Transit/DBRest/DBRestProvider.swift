import Foundation

/// db-rest (https://v6.db.transport.rest), unofficial wrapper around the DB APIs.
public struct DBRestProvider: TransitProvider {
    public static let defaultBaseURL = URL(string: "https://v6.db.transport.rest")!

    public let source = DataSource.dbRest
    public var baseURL: URL
    let http: HTTPClient

    public init(baseURL: URL = DBRestProvider.defaultBaseURL, http: HTTPClient = HTTPClient(timeout: 8)) {
        self.baseURL = baseURL
        self.http = http
    }

    func url(_ path: String, _ items: [URLQueryItem]) -> URL {
        baseURL.appending(path: path).appending(queryItems: items)
    }

    public func searchStations(_ query: String) async throws -> [Station] {
        let locations = try await http.get(url("locations", [
            .init(name: "query", value: query),
            .init(name: "results", value: "10"),
            .init(name: "addresses", value: "false"),
            .init(name: "poi", value: "false"),
        ]), as: [DBLocation].self)
        return locations.compactMap { $0.toStation() }
    }

    public func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        guard query.from.source == .dbRest, query.to.source == .dbRest else {
            throw TransitError.invalidInput("Station stammt nicht aus db-rest")
        }
        var items: [URLQueryItem] = [
            .init(name: "from", value: query.from.id),
            .init(name: "to", value: query.to.id),
            .init(name: "results", value: "6"),
            .init(name: "stopovers", value: "true"),
            .init(name: "remarks", value: "true"),
        ]
        if let cursor = query.cursor {
            items.appendCursor(cursor)
        } else {
            items.append(.init(name: query.isArrival ? "arrival" : "departure", value: JSONDecoding.isoString(query.date)))
        }
        let response = try await http.get(url("journeys", items), as: DBJourneysResponse.self)
        let journeys = response.journeys.compactMap { dto -> Journey? in
            let legs = dto.legs.compactMap { $0.toLeg() }
            return legs.count == dto.legs.count && !legs.isEmpty ? Journey(legs: legs, source: .dbRest) : nil
        }
        return JourneyPage(
            journeys: journeys,
            earlierCursor: response.earlierRef.map { "earlierThan=\($0)" },
            laterCursor: response.laterRef.map { "laterThan=\($0)" },
            source: .dbRest
        )
    }

    public func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int) async throws -> [BoardEntry] {
        let entries = try await rawBoard(kind, at: station, date: date, duration: duration)
        guard kind == .departures else { return entries }
        // DB departure boards omit trains without boarding ("nur Ausstieg"). They show up as
        // arrivals that are not departures – but so do trains ending here, so check the trip.
        let arrivals = (try? await rawBoard(.arrivals, at: station, date: date, duration: duration)) ?? []
        let departureTrips = Set(entries.map(\.tripId))
        let candidates = arrivals.filter { !departureTrips.contains($0.tripId) && $0.line.product.isTrain }.prefix(8)
        let exitOnly = await withTaskGroup(of: BoardEntry?.self) { group in
            for arrival in candidates {
                group.addTask {
                    guard let trip = try? await trip(id: arrival.tripId),
                          let index = trip.stopovers.firstIndex(where: { $0.station.isSamePlace(as: station) }),
                          index < trip.stopovers.count - 1 else { return nil }
                    var entry = arrival
                    entry.kind = .departures
                    entry.otherEnd = trip.direction ?? trip.destination?.name
                    entry.time = trip.stopovers[index].departure ?? arrival.time
                    entry.access = .exitOnly
                    entry.terminatesOrOriginatesHere = false
                    return entry
                }
            }
            var result: [BoardEntry] = []
            for await entry in group { if let entry { result.append(entry) } }
            return result
        }
        return entries + exitOnly
    }

    func rawBoard(_ kind: BoardKind, at station: Station, date: Date, duration: Int) async throws -> [BoardEntry] {
        let path = "stops/\(station.evaNumber ?? station.id)/\(kind == .departures ? "departures" : "arrivals")"
        let response = try await http.get(url(path, [
            .init(name: "when", value: JSONDecoding.isoString(date)),
            .init(name: "duration", value: String(duration)),
            .init(name: "results", value: "200"),
            .init(name: "remarks", value: "true"),
        ]), as: DBBoardResponse.self)
        return response.items.compactMap { $0.toEntry(kind: kind, fallbackStation: station) }
    }

    public func trip(id: String) async throws -> Trip {
        let response = try await http.get(url("trips/\(id)", [
            .init(name: "stopovers", value: "true"),
            .init(name: "remarks", value: "true"),
        ]), as: DBTripResponse.self)
        let dto = response.trip
        return Trip(
            id: dto.id, line: dto.line?.toLine(), direction: dto.direction,
            stopovers: (dto.stopovers ?? []).compactMap { $0.toStopover() },
            cancelled: dto.cancelled ?? false, remarks: DBRemark.texts(dto.remarks), source: .dbRest
        )
    }
}

private extension Array where Element == URLQueryItem {
    mutating func appendCursor(_ cursor: String) {
        let parts = cursor.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { append(URLQueryItem(name: parts[0], value: parts[1])) }
    }
}
