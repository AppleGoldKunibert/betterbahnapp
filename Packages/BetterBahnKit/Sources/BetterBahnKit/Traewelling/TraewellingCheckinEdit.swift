import Foundation

public extension TraewellingClient {
    /// The check-in that is currently running, or `nil` when nothing is checked in.
    func activeStatus() async throws -> TraewellingStatus? {
        let data = try await authorizedData("user/statuses/active")
        // 204 No Content (an empty body, sometimes a literal `null`) means nothing is running.
        guard !data.isEmpty, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) != "null" else {
            return nil
        }
        return try JSONDecoding.decoder.decode(DataWrapper<TraewellingStatus>.self, from: data).data
    }

    /// The user's own check-in covering `leg` – the running one if it matches, otherwise the most
    /// recent matching check-in. Used to offer adjusting a check-in whose exit no longer fits the
    /// journey (e.g. checked in to C, but now getting off at B).
    func checkin(matching leg: Leg) async throws -> TraewellingStatus? {
        if let active = try await activeStatus(), Self.covers(active, leg) { return active }
        let user = try await currentUser()
        let recent = try await statuses(username: user.username, page: 1)
        return recent.statuses.first { Self.covers($0, leg) }
    }

    /// Whether a check-in describes the same ride as `leg`.
    static func covers(_ status: TraewellingStatus, _ leg: Leg) -> Bool {
        guard let checkedIn = status.journey(geometry: nil)?.legs.first else { return false }
        return RideMatch.isSameRide(checkedIn, leg)
    }

    /// Moves an existing check-in's exit to `station`. Träwelling only accepts a stopover of the
    /// checked-in trip itself, so the stop is resolved against the trip's own stop list first –
    /// the same source Träwelling validates the request against.
    @discardableResult
    func changeDestination(of status: TraewellingStatus, to station: Station,
                           arrival: Date? = nil) async throws -> TraewellingStatus {
        let lineName = status.checkin.lineName ?? ""
        guard let hafasId = status.checkin.hafasId, !hafasId.isEmpty else {
            throw TraewellingError.tripNotFound(lineName.isEmpty ? "Fahrt" : lineName)
        }
        let trip = try await trip(tripID: hafasId, lineName: lineName)
        guard let stop = Self.matchStop(trip.stopovers, station: station, arrival: arrival),
              let plannedArrival = stop.arrivalPlanned else {
            throw TraewellingError.stopNotOnTrip(station.name, tripStops: trip.stopovers.map(\.name))
        }
        let body: [String: Any] = [
            "destinationId": stop.stationID,
            "destinationArrivalPlanned": JSONDecoding.isoString(plannedArrival),
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await authorized("status/\(status.id)", method: "PUT", body: data,
                                    as: DataWrapper<TraewellingStatus>.self).data
    }
}
