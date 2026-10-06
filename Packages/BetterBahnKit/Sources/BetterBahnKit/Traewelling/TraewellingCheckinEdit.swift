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

    /// One of the user's check-ins.
    func status(id: Int) async throws -> TraewellingStatus {
        try await authorized("status/\(id)", as: DataWrapper<TraewellingStatus>.self).data
    }

    /// Changes a check-in's text, visibility and trip type. An empty text removes it.
    @discardableResult
    func updateStatus(id: Int, body: String, visibility: TraewellingVisibility,
                      business: TraewellingBusiness) async throws -> TraewellingStatus {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: [String: Any] = [
            "body": text.isEmpty ? NSNull() : String(text.prefix(280)) as Any,
            "visibility": visibility.rawValue,
            "business": business.rawValue,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try await authorized("status/\(id)", method: "PUT", body: data,
                                    as: DataWrapper<TraewellingStatus>.self).data
    }

    /// Deletes one of the user's check-ins. One Träwelling no longer knows (404) counts as deleted.
    func deleteStatus(id: Int) async throws {
        do {
            _ = try await authorizedData("status/\(id)", method: "DELETE")
        } catch TraewellingError.api(let status, _) where status == 404 {}
    }

    /// The tags (seat, wagon, …) of a check-in.
    func tags(statusId: Int) async throws -> [StatusTag] {
        try await authorized("status/\(statusId)/tags", as: DataWrapper<[StatusTag]>.self).data
    }

    /// Changes a tag's value; its key stays.
    @discardableResult
    func updateTag(statusId: Int, _ tag: StatusTag) async throws -> StatusTag {
        let body: [String: Any] = ["key": tag.key, "value": tag.value,
                                   "visibility": (tag.visibility ?? .publicVisible).rawValue]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await authorized("status/\(statusId)/tags/\(tag.key)", method: "PUT", body: data,
                                    as: DataWrapper<StatusTag>.self).data
    }

    /// Removes a tag. One that is already gone (404) counts as removed.
    func deleteTag(statusId: Int, key: String) async throws {
        do {
            _ = try await authorizedData("status/\(statusId)/tags/\(key)", method: "DELETE")
        } catch TraewellingError.api(let status, _) where status == 404 {}
    }

    /// Brings a check-in's tags from `old` to `new` (see `StatusTagChanges`) and returns them as they now are.
    @discardableResult
    func applyTagChanges(statusId: Int, from old: [StatusTag], to new: [StatusTag]) async throws -> [StatusTag] {
        let changes = StatusTagChanges(from: old, to: new)
        for key in changes.removed { try await deleteTag(statusId: statusId, key: key) }
        for tag in changes.updated { try await updateTag(statusId: statusId, tag) }
        for tag in changes.added {
            try await addTag(statusId: statusId, key: tag.key, value: tag.value, visibility: tag.visibility ?? .publicVisible)
        }
        return try await tags(statusId: statusId)
    }

    /// Where to get off when checking out of `leg` at `now`: the last stop the train has reached, or
    /// its next stop when it hasn't reached one since boarding. `nil` unless the ride is under way and
    /// there is a stop before its destination where Träwelling can end it (a scheduled stop that
    /// lets passengers off and isn't cancelled).
    static func earlyExit(on leg: Leg, at now: Date) -> Stopover? {
        guard leg.departure.best <= now, now < leg.arrival.best, leg.stopovers.count > 2 else { return nil }
        let exits = leg.stopovers.dropFirst().dropLast().filter { stop in
            stop.arrival != nil && !stop.arrivalCancelled && !stop.isAdditional
                && (stop.access == .normal || stop.access == .exitOnly)
        }
        return exits.last { $0.arrival!.best <= now } ?? exits.first
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

/// What has to happen to a check-in's tags to turn `old` into `new`: tags whose value is empty in
/// `new` are removed, like ones left out.
public struct StatusTagChanges: Equatable, Sendable {
    public var added: [StatusTag] = []
    public var updated: [StatusTag] = []
    /// Keys of the removed tags.
    public var removed: [String] = []

    public init(from old: [StatusTag], to new: [StatusTag]) {
        let wanted = new.map {
            StatusTag(key: $0.key, value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines), visibility: $0.visibility)
        }.filter { !$0.value.isEmpty }
        let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for tag in wanted where seen.insert(tag.key).inserted {
            if let previous = oldByKey[tag.key] {
                if previous.value != tag.value {
                    updated.append(StatusTag(key: tag.key, value: tag.value, visibility: tag.visibility ?? previous.visibility))
                }
            } else {
                added.append(tag)
            }
        }
        removed = old.map(\.key).filter { !seen.contains($0) }
    }

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
}
