import Foundation

/// What DB's dispatchers decided for a transfer: whether the departing train waits for the arriving
/// one. Only known for transfers DB tracks and only close to the time, from bahn.expert's connections
/// (RIS::Connections `dispositionStatus`).
public enum TransferDisposition: String, Codable, Sendable, Hashable {
    case waiting
    case notWaiting

    /// `NOT_WAITING` / `WAITING`; anything else (or a missing status) means nothing was decided.
    init?(type: String?) {
        guard let type = type?.uppercased() else { return nil }
        if type.contains("NOT") { self = .notWaiting } else if type.contains("WAIT") { self = .waiting } else { return nil }
    }

    public var title: String {
        switch self {
        case .waiting: "Anschluss wartet"
        case .notWaiting: "Anschluss wartet nicht"
        }
    }

    /// "RE3 wartet in Berlin Hbf (nicht) auf ICE 91."
    public func message(arriving: Leg, departing: Leg) -> String {
        let a = arriving.line?.name ?? "Zug", d = departing.line?.name ?? "Anschlusszug"
        let station = departing.origin.displayName
        return switch self {
        case .waiting: "\(d) wartet in \(station) auf \(a)."
        case .notWaiting: "\(d) wartet in \(station) nicht auf \(a)."
        }
    }
}

/// DB's decision for one transfer of a journey, as looked up by `BahnExpertClient.dispositions(in:now:)`.
public struct TransferDispositionUpdate: Sendable, Hashable {
    public var arriving: Leg
    public var departing: Leg
    /// nil: nothing decided (any more).
    public var disposition: TransferDisposition?

    /// Notified once per decision; a changed decision (waits → doesn't wait) notifies again.
    public var notificationID: String? {
        disposition.map { "disposition|\(departing.id)|\($0.rawValue)" }
    }
}

extension BahnExpertClient {
    struct ConnectionsResponse: Decodable {
        struct Connection: Decodable {
            struct Transport: Decodable {
                var category: String?
                var number: Int?
                var journeyDescription: String?
                var line: String?
            }
            struct Disposition: Decodable { var type: String? }
            var transport: Transport
            var timeSchedule: Date?
            var dispositionStatus: Disposition?
        }
        var connections: [Connection]
    }

    struct DetailsWithIDs: Decodable {
        struct Stop: Decodable {
            struct Place: Decodable { var evaNumber: String }
            struct Event: Decodable { var scheduledTime: Date; var id: String? }
            var stopPlace: Place
            var arrival: Event?
        }
        var stops: [Stop]
    }

    /// Whether `departing` waits for `arriving`, as DB's dispatchers decided. nil when bahn.expert
    /// doesn't know the arriving train, doesn't list the connection, or nothing was decided.
    public func disposition(from arriving: Leg, to departing: Leg) async throws -> TransferDisposition? {
        guard let ref = Self.reference(for: arriving.line), let journeyNumber = Int(ref.number) else { return nil }
        let date = BahnDeClient.berlinDay(arriving.departure.planned)
        // Without an administration, so regional trains of other operators (ODEG's "OE") are found too.
        let found: [FoundJourney] = try await call("journey/find", input: [
            "json": [
                "journeyNumber": journeyNumber, "category": ref.category,
                "initialDepartureDate": "\(date)T12:00:00.000Z", "withOEV": true, "limit": 5,
            ] as [String: Any],
            "meta": [["date", "initialDepartureDate"]],
        ])
        for journey in found where journey.train?.journeyNumber == journeyNumber {
            let details: DetailsWithIDs = try await call("journey/detailsByJourneyId", input: ["json": journey.journeyId])
            // The same number can be another train elsewhere; the right one stops where the leg ends.
            guard let stop = Self.arrivalStop(of: arriving, in: details.stops), let arrivalId = stop.arrival?.id else { continue }
            let response: ConnectionsResponse = try await call("connections/connections", input: [
                "json": ["journeyId": journey.journeyId, "arrivalId": arrivalId, "evaNumber": stop.stopPlace.evaNumber],
            ])
            return Self.connection(to: departing, in: response.connections)
                .flatMap { TransferDisposition(type: $0.dispositionStatus?.type) }
        }
        return nil
    }

    /// The transfers worth asking about: neither train cancelled, the arriving one gets in between 15 minutes
    /// ago and 3 hours from now (DB's dispatchers only decide close to the time).
    static func transfersToAsk(in journey: Journey, now: Date) -> [(arriving: Leg, departing: Leg)] {
        let transit = journey.transitLegs
        return zip(transit, transit.dropFirst()).filter { arriving, departing in
            !arriving.cancelled && !departing.cancelled
                && arriving.arrival.best > now.addingTimeInterval(-15 * 60)
                && arriving.arrival.best < now.addingTimeInterval(3 * 3600)
        }.map { (arriving: $0, departing: $1) }
    }

    /// DB's decisions for the journey's upcoming transfers, side by side. Transfers whose lookup failed
    /// are left out, so callers keep what they knew.
    public func dispositions(in journey: Journey, now: Date = .now) async -> [TransferDispositionUpdate] {
        await withTaskGroup(of: TransferDispositionUpdate?.self) { group in
            for (arriving, departing) in Self.transfersToAsk(in: journey, now: now) {
                group.addTask {
                    do {
                        let disposition = try await self.disposition(from: arriving, to: departing)
                        return TransferDispositionUpdate(arriving: arriving, departing: departing, disposition: disposition)
                    } catch {
                        return nil
                    }
                }
            }
            var updates: [TransferDispositionUpdate] = []
            for await case let update? in group { updates.append(update) }
            return updates
        }
    }

    /// Long-distance trains by number, regional and S-Bahn trains by run number.
    static func reference(for line: Line?) -> (category: String, number: String)? {
        BahnDeClient.trainReference(for: line)
            ?? BahnDeClient.regionalReference(for: line, products: [.regionalExpress, .regional, .suburban])
    }

    static func arrivalStop(of leg: Leg, in stops: [DetailsWithIDs.Stop]) -> DetailsWithIDs.Stop? {
        let arrivals = stops.filter { $0.arrival != nil }
        if let eva = leg.destination.evaNumber, let stop = arrivals.first(where: { $0.stopPlace.evaNumber == eva }) {
            return stop
        }
        return arrivals.first { abs($0.arrival!.scheduledTime.timeIntervalSince(leg.arrival.planned)) < 60 }
    }

    /// The departing train among the connections: by run number, else by scheduled time and name.
    static func connection(to leg: Leg, in connections: [ConnectionsResponse.Connection]) -> ConnectionsResponse.Connection? {
        func sameTime(_ connection: ConnectionsResponse.Connection) -> Bool {
            connection.timeSchedule.map { abs($0.timeIntervalSince(leg.departure.planned)) < 60 } ?? false
        }
        if let number = (reference(for: leg.line)?.number).flatMap(Int.init),
           let match = connections.first(where: { $0.transport.number == number && sameTime($0) }) {
            return match
        }
        guard let name = leg.line?.name else { return nil }
        let key = compact(name)
        return connections.first { connection in
            sameTime(connection) && [connection.transport.journeyDescription, connection.transport.line]
                .contains { $0.map(compact) == key }
        }
    }

    private static func compact(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "").uppercased()
    }
}
