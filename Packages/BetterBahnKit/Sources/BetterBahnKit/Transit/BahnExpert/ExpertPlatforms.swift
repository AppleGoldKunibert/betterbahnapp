import Foundation

/// The platforms bahn.expert has for a train's stops. bahn.de's journey details have none at the
/// stations of other railways days ahead (the SBB's and ÖBB's platforms of EC 163 or NJ 403 only
/// show up there once DB's dispatching has them), but bahn.expert lists the ones its sources know,
/// also for the Swiss and Austrian part of a train. Used where bahn.de and Transitous left a gap.
extension BahnExpertClient {
    struct RunPlatforms: Decodable {
        struct Stop: Decodable {
            struct Place: Decodable { var evaNumber: String; var name: String }
            struct Event: Decodable {
                var scheduledTime: Date
                var scheduledPlatform: String?
                var platform: String?
            }
            var stopPlace: Place
            var arrival: Event?
            var departure: Event?
        }
        var stops: [Stop]
    }

    /// The run's stops as `JourneyStop`s with their planned times and platforms, so they can be laid
    /// over a leg or trip like bahn.de's (`BahnDeClient.fillingMissingPlatforms`, by time alone: the names differ).
    static func journeyStops(from run: RunPlatforms) -> [JourneyStop] {
        run.stops.map { stop in
            func platform(_ event: RunPlatforms.Stop.Event?) -> PlatformInfo? {
                guard let event, event.scheduledPlatform != nil || event.platform != nil else { return nil }
                return PlatformInfo(planned: event.scheduledPlatform, actual: event.platform)
            }
            return JourneyStop(evaNumber: stop.stopPlace.evaNumber, name: stop.stopPlace.name,
                               arrival: stop.arrival.map { TimeInfo(planned: $0.scheduledTime, actual: nil) },
                               departure: stop.departure.map { TimeInfo(planned: $0.scheduledTime, actual: nil) },
                               arrivalPlatform: platform(stop.arrival), departurePlatform: platform(stop.departure))
        }
    }

    /// The stops of the run `category` + `number` that is riding at `time`. bahn.expert files a run by the
    /// day it starts, which for a night train is the day before the leg's own: that day is tried too.
    /// Empty when bahn.expert has no such run or none of them has a stop at `time`.
    public func platformStops(category: String, number: Int, at time: Date) async throws -> [JourneyStop] {
        for day in [BahnDeClient.berlinDay(time), BahnDeClient.berlinDay(time.addingTimeInterval(-24 * 3600))] {
            let runs = try await findTrains(number: number, category: category, day: day)
            guard let run = runs.first(where: { $0.number == number && $0.category.uppercased() == category.uppercased() }) else { continue }
            let details: RunPlatforms = try await call("journey/detailsByJourneyId", input: ["json": run.journeyId])
            let stops = Self.journeyStops(from: details)
            let riding = stops.contains { stop in
                [stop.arrival, stop.departure].contains { $0.map { abs($0.planned.timeIntervalSince(time)) < 60 } ?? false }
            }
            if riding { return stops }
        }
        return []
    }

    /// The train to look platforms up for: DB's long-distance trains of another railway's (the SBB's EC 163,
    /// ÖBB's RJX 161) and the ones only bahn.expert and vagonweb know (`BahnDeClient.takesOnlyPlatforms`).
    /// DB's own trains get theirs from bahn.de, so they aren't asked again here.
    public static func platformReference(for line: Line?) -> (category: String, number: Int)? {
        guard let line else { return nil }
        let ref: (category: String, number: String)
        if let found = BahnDeClient.plannedOnlyReference(for: line) {
            ref = found
        } else if let found = BahnDeClient.trainReference(for: line), isForeignOperator(line.operatorName) {
            ref = found
        } else {
            return nil
        }
        return Int(ref.number).map { (ref.category, $0) }
    }

    /// Whether `name` is a railway other than DB ("Schweizerische Bundesbahnen", "OEBB Personenverkehr AG").
    static func isForeignOperator(_ name: String?) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        return !(name.hasPrefix("db ") || name.contains("deutsche bahn"))
    }
}

/// Asks bahn.expert for a run's platforms at most once in a while, as `ExpertTimesCache` does for times.
actor ExpertPlatformsCache {
    static let shared = ExpertPlatformsCache()
    static let maxAge: TimeInterval = 30 * 60

    private struct Entry { let date: Date; let stops: [JourneyStop] }
    private var entries: [String: Entry] = [:]
    private var loading: [String: Task<[JourneyStop], Never>] = [:]

    func stops(category: String, number: Int, at time: Date, using client: BahnExpertClient, now: Date = .now) async -> [JourneyStop] {
        let key = "\(category) \(number) \(Int(time.timeIntervalSince1970))"
        if let entry = entries[key], now.timeIntervalSince(entry.date) < Self.maxAge { return entry.stops }
        if let task = loading[key] { return await task.value }
        let task = Task { (try? await client.platformStops(category: category, number: number, at: time)) ?? [] }
        loading[key] = task
        let stops = await task.value
        loading[key] = nil
        // A failed answer is remembered as well, so a bahn.expert outage isn't asked again on every refresh.
        entries[key] = Entry(date: now, stops: stops)
        return stops
    }
}

extension BahnExpertClient {
    /// `leg` with the platforms it still lacks from bahn.expert. Unchanged for a train `platformReference`
    /// doesn't name, a leg that has them all, or when bahn.expert has nothing.
    public func fillingMissingPlatforms(in leg: Leg) async -> Leg {
        guard BahnDeClient.lacksPlatforms(leg), let ref = Self.platformReference(for: leg.line) else { return leg }
        let stops = await ExpertPlatformsCache.shared.stops(category: ref.category, number: ref.number, at: leg.departure.planned, using: self)
        return stops.isEmpty ? leg : BahnDeClient.fillingMissingPlatforms(in: leg, from: stops, matchingByTimeAlone: true)
    }

    /// `stopovers` of a trip of `line` with the platforms they still lack from bahn.expert.
    public func fillingMissingPlatforms(in stopovers: [Stopover], line: Line?) async -> [Stopover] {
        guard let ref = Self.platformReference(for: line),
              stopovers.contains(where: { ($0.arrival != nil && $0.arrivalPlatform?.best == nil) || ($0.departure != nil && $0.departurePlatform?.best == nil) }),
              let first = stopovers.lazy.compactMap({ $0.departure?.planned ?? $0.arrival?.planned }).first
        else { return stopovers }
        let stops = await ExpertPlatformsCache.shared.stops(category: ref.category, number: ref.number, at: first, using: self)
        return stops.isEmpty ? stopovers : BahnDeClient.fillingMissingPlatforms(in: stopovers, from: stops, matchingByTimeAlone: true)
    }
}
