import Foundation

/// What the people the user follows on Träwelling are riding right now (#196).
public struct FollowedCheckins: Sendable {
    /// Others' check-ins on a train now or leaving soon (see `TraewellingClient.checkedIn`), the latest departure first.
    public var statuses: [TraewellingStatus]
    /// Whether the user has likes on; Träwelling asks apps to offer liking only then.
    public var likesEnabled: Bool

    public init(statuses: [TraewellingStatus], likesEnabled: Bool) {
        self.statuses = statuses
        self.likesEnabled = likesEnabled
    }
}

public extension TraewellingClient {
    /// No ride runs longer, so the dashboard isn't paged back further for rides still running.
    static let longestRide: TimeInterval = 12 * 3600

    /// How long before the train leaves a check-in shows: the dashboard has nothing that leaves later.
    static let boardingWindow: TimeInterval = 20 * 60

    /// The check-ins of the people the user follows that are under way at `now` or leave soon, from
    /// Träwelling's dashboard (the last 7 days of check-ins by followed users and the user, departing
    /// before 20 minutes from now, latest departure first).
    func followedCheckins(at now: Date = .now, maxPages: Int = 3) async throws -> FollowedCheckins {
        let user = try await currentUser()
        var found: [TraewellingStatus] = []
        for page in 1...max(1, maxPages) {
            let result = try await authorized("dashboard", query: [.init(name: "page", value: String(page))], as: StatusPage.self)
            found += result.data
            // Once a page reaches back further than any ride lasts, nothing older is still running.
            guard result.links?.next != nil, let oldest = result.data.last.flatMap({ $0.checkin.origin.departurePlanned ?? $0.checkin.start }),
                  oldest > now.addingTimeInterval(-Self.longestRide) else { break }
        }
        return FollowedCheckins(statuses: Self.checkedIn(found, excludingUser: user.id, at: now),
                                likesEnabled: user.likesEnabled ?? true)
    }

    /// The check-ins of others in `statuses` whose ride hasn't ended at `now` and that are on the train
    /// or wait for it to leave within `boardingWindow` (by plan, so a delay doesn't hide them), each once.
    /// Ones without a user are left out too: they can't be told from the user's own.
    static func checkedIn(_ statuses: [TraewellingStatus], excludingUser me: Int, at now: Date) -> [TraewellingStatus] {
        var seen = Set<Int>()
        return statuses.filter { status in
            guard seen.insert(status.id).inserted, let user = status.user, user.id != me,
                  let start = status.checkin.start, let end = status.checkin.end else { return false }
            let leaves = min(start, status.checkin.origin.departurePlanned ?? start)
            return leaves <= now.addingTimeInterval(boardingWindow) && now < end
        }
        .sorted { ($0.checkin.start ?? .distantPast) > ($1.checkin.start ?? .distantPast) }
    }

    /// Likes someone's check-in and returns how many like it now. One liked before (409) counts as liked.
    @discardableResult
    func like(statusId: Int) async throws -> Int? {
        do {
            return Self.likeCount(in: try await authorizedData("status/\(statusId)/like", method: "POST"))
        } catch TraewellingError.collision {
            return nil
        } catch TraewellingError.api(let status, _) where status == 403 {
            throw TraewellingError.likeNotAllowed
        }
    }

    /// Takes the user's like back and returns how many like the check-in now. One not liked (404) counts as done.
    @discardableResult
    func unlike(statusId: Int) async throws -> Int? {
        do {
            return Self.likeCount(in: try await authorizedData("status/\(statusId)/like", method: "DELETE"))
        } catch TraewellingError.api(let status, _) where status == 404 {
            return nil
        } catch TraewellingError.api(let status, _) where status == 403 {
            throw TraewellingError.likeNotAllowed
        }
    }

    /// The like count in Träwelling's answer to a like (`{"data":{"count":3}}`).
    static func likeCount(in data: Data) -> Int? {
        struct Count: Decodable, Sendable { var count: Int }
        return (try? JSONDecoding.decoder.decode(DataWrapper<Count>.self, from: data))?.data.count
    }
}

public extension CombinedProvider {
    /// How far a planned time may differ from the check-in's and still be the same train.
    static let checkinTolerance: TimeInterval = 60

    /// The timetable run of someone's Träwelling check-in (#196), so it shows like any other train:
    /// the train leaving the check-in's origin at its planned time under its name or number, from the
    /// boarding stop to the exit. `nil` for trips typed in on Träwelling and when no train fits.
    func leg(forCheckin status: TraewellingStatus) async throws -> Leg? {
        guard !status.checkin.isManualTrip, let ride = status.journey(geometry: nil)?.legs.first else { return nil }
        let entries = try await departures(at: ride.origin, date: ride.departure.planned.addingTimeInterval(-2 * 60), duration: 6)
        for entry in Self.candidates(for: status, departingAt: ride.departure.planned, in: entries) {
            guard let trip = try? await trip(id: entry.tripId, source: entry.source) else { continue }
            if let leg = Self.leg(of: trip, riding: ride) { return leg }
        }
        return nil
    }

    /// Board entries that may be the checked-in train: leaving at its planned time under its name,
    /// or under its run number (Träwelling's `journeyNumber`, e.g. a regional train's 4711).
    static func candidates(for status: TraewellingStatus, departingAt planned: Date, in entries: [BoardEntry]) -> [BoardEntry] {
        entries.filter { entry in
            guard abs(entry.time.planned.timeIntervalSince(planned)) <= checkinTolerance else { return false }
            if let name = status.checkin.lineName, TrainRoutePlanner.matches(Line.normalize(name), entry.line) { return true }
            guard let number = status.checkin.journeyNumber.map(String.init) else { return false }
            return [entry.line.number, entry.line.tripNumber].contains(number)
        }
    }

    /// The part of `trip` the check-in `ride` covers: from the stop it leaves at the ride's planned
    /// departure to the ride's exit (same place, or arriving at the planned time nearby – feeds name
    /// some stations differently).
    static func leg(of trip: Trip, riding ride: Leg) -> Leg? {
        func same(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) <= checkinTolerance } ?? false }
        func near(_ station: Station, _ other: Station) -> Bool {
            guard let a = station.coordinate, let b = other.coordinate else { return true }
            return a.distance(to: b) < 2_000
        }
        guard let start = trip.stopovers.firstIndex(where: {
            same($0.departure?.planned, ride.departure.planned) && ($0.station.isSamePlace(as: ride.origin) || near($0.station, ride.origin))
        }) else { return nil }
        let rest = trip.stopovers.indices.filter { $0 > start }
        let end = rest.first { trip.stopovers[$0].station.isSamePlace(as: ride.destination) }
            ?? rest.first { same(trip.stopovers[$0].arrival?.planned, ride.arrival.planned) && near(trip.stopovers[$0].station, ride.destination) }
        guard let end else { return nil }
        return trip.leg(fromIndex: start, toIndex: end)
    }
}
