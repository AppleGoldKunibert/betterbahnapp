import Foundation

/// bahn.expert's live times for one run of a train, as the referee when bahn.de and DB Timetables
/// disagree (`BahnDeClient.applyingLiveTimes(from:to:keepingDelays:expert:)`). Keyed by the stop's EVA
/// number and its planned time, so a station passed twice can't mix them up.
public struct ExpertTimes: Sendable, Hashable {
    public enum Side: Sendable { case arrival, departure }

    struct Entry: Sendable, Hashable {
        var eva: String
        var planned: Date
        var actual: Date
        var side: Side
    }

    var entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// The live time bahn.expert has for `side` of the stop `eva` planned at `planned` (±1 min).
    func actual(eva: String, planned: Date, side: Side) -> Date? {
        entries.first { $0.eva == eva && $0.side == side && abs($0.planned.timeIntervalSince(planned)) < 60 }?.actual
    }
}

extension BahnExpertClient {
    struct RunTimes: Decodable {
        struct Stop: Decodable {
            struct Place: Decodable { var evaNumber: String }
            struct Event: Decodable { var scheduledTime: Date; var time: Date? }
            var stopPlace: Place
            var arrival: Event?
            var departure: Event?
        }
        var stops: [Stop]
    }

    /// The live times of the run `category` + `number` that started on `day` (`yyyy-MM-dd`, Europe/Berlin).
    /// bahn.expert's times come from the same dispatching data as DB Timetables, but through DB's other
    /// systems, so it is a second opinion. The category is only a hint to bahn.expert (see `findTrains`);
    /// the run must have exactly this number.
    public func liveTimes(category: String?, number: Int, day: String) async throws -> ExpertTimes {
        let runs = try await findTrains(number: number, category: category, day: day)
        let wanted = category?.uppercased()
        guard let run = runs.first(where: { $0.number == number && (wanted == nil || $0.category.uppercased() == wanted) })
        else { throw TransitError.notFound("\(category ?? "") \(number)") }
        let details: RunTimes = try await call("journey/detailsByJourneyId", input: ["json": run.journeyId])
        var entries: [ExpertTimes.Entry] = []
        for stop in details.stops {
            if let event = stop.arrival, let time = event.time {
                entries.append(.init(eva: stop.stopPlace.evaNumber, planned: event.scheduledTime, actual: time, side: .arrival))
            }
            if let event = stop.departure, let time = event.time {
                entries.append(.init(eva: stop.stopPlace.evaNumber, planned: event.scheduledTime, actual: time, side: .departure))
            }
        }
        return ExpertTimes(entries: entries)
    }
}

/// Asks bahn.expert for a train's live times, at most once in a while per run: the stop lists and the
/// journey refresh both ask, and bahn.expert is a community service.
actor ExpertTimesCache {
    static let shared = ExpertTimesCache()
    static let maxAge: TimeInterval = 120

    private struct Entry { let date: Date; let times: ExpertTimes? }
    private var entries: [String: Entry] = [:]

    func times(category: String?, number: Int, day: String, using client: BahnExpertClient, now: Date = .now) async -> ExpertTimes? {
        let key = "\(category ?? "") \(number) \(day)"
        if let entry = entries[key], now.timeIntervalSince(entry.date) < Self.maxAge { return entry.times }
        let times = try? await client.liveTimes(category: category, number: number, day: day)
        // A failed answer is remembered as well, so a bahn.expert outage isn't asked again on every refresh.
        entries[key] = Entry(date: now, times: times)
        return times
    }
}
