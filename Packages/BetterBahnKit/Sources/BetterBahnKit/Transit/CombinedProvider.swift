import Foundation

/// Transitous is primary. A separately configured provider can supply failover.
/// bahn.de remains a station-search fallback and the source for coach sequences and journey details;
/// when bahn.de has no coach sequence (yet), vagonweb.cz supplies the train type and planned Wagenreihung, with bahn.expert as the
/// fallback for the train type; bahn.jetzt supplies live train positions.
public final class CombinedProvider: TransitProvider {
    public var source: DataSource { primary.source }
    public let primary: any TransitProvider
    public let fallback: (any TransitProvider)?
    public let bahnDe: BahnDeClient?
    public let bahnExpert: BahnExpertClient?
    public let vagonweb: VagonwebClient?
    public let bahnJetzt: BahnJetztClient?
    private let health: Health
    private let renumbered = RenumberedTrips()

    public init(primary: any TransitProvider = TransitousProvider(),
                fallback: (any TransitProvider)? = nil,
                bahnDe: BahnDeClient? = BahnDeClient(),
                bahnExpert: BahnExpertClient? = BahnExpertClient(),
                vagonweb: VagonwebClient? = VagonwebClient(),
                bahnJetzt: BahnJetztClient? = BahnJetztClient(),
                cooldown: TimeInterval = 120) {
        self.bahnDe = bahnDe
        self.bahnExpert = bahnExpert
        self.vagonweb = vagonweb
        self.bahnJetzt = bahnJetzt
        self.primary = primary
        self.fallback = fallback
        self.health = Health(cooldown: cooldown)
    }

    actor Health {
        let cooldown: TimeInterval
        var failedAt: Date?
        init(cooldown: TimeInterval) { self.cooldown = cooldown }
        var primaryAvailable: Bool {
            guard let failedAt else { return true }
            return Date.now.timeIntervalSince(failedAt) > cooldown
        }
        func markFailed() { failedAt = .now }
        func markOK() { failedAt = nil }
    }

    /// Fail over on errors or deadlines only when another provider is configured.
    private func withFallback<T: Sendable>(
        deadline: Duration = .seconds(8),
        _ primaryWork: @escaping @Sendable (any TransitProvider) async throws -> T,
        _ fallbackWork: @Sendable (any TransitProvider) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let available = await health.primaryAvailable
        if fallback == nil || available {
            let primary = self.primary
            do {
                let result = try await Self.withDeadline(deadline) { try await primaryWork(primary) }
                await health.markOK()
                return result
            } catch {
                // The caller went away (e.g. user kept typing) – don't mark the provider unhealthy.
                if Task.isCancelled { throw CancellationError() }
                guard fallback != nil else { throw error }
                await health.markFailed()
            }
        }
        try Task.checkCancellation()
        guard let fallback else { throw TransitError.invalidInput("Keine Ersatzdatenquelle verfügbar.") }
        return try await fallbackWork(fallback)
    }

    /// Runs `operation`, giving up with `TransitError.timeout` after `deadline`. Returns as soon as the
    /// deadline passes: `operation` is cancelled, but a request that is slow to stop (a URL load
    /// winding down) doesn't hold up the caller, as waiting for it in a task group would.
    static func withDeadline<T: Sendable>(_ deadline: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = DeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, deadline: deadline, operation: operation)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// Search Transitous first so fresh station IDs are ready for routing.
    public func searchStations(_ query: String) async throws -> [Station] {
        try await searchStations(query, near: nil)
    }

    public func searchStations(_ query: String, near location: Coordinate?) async throws -> [Station] {
        do {
            let stations = try await withFallback(deadline: .milliseconds(2500),
                { try await $0.searchStations(query, near: location) }, { try await $0.searchStations(query, near: location) })
            // bahn.de's hits for one or two letters are unordered noise ("Pinarolo Po" for "Po").
            if !stations.isEmpty || bahnDe == nil || Self.isShortQuery(query) { return stations }
        } catch {
            try Task.checkCancellation()
            guard let bahnDe else { throw error }
            return try await Self.withDeadline(.milliseconds(2500)) { try await bahnDe.searchStations(query) }
        }
        try Task.checkCancellation()
        guard let bahnDe else { return [] }
        return try await Self.withDeadline(.milliseconds(2500)) { try await bahnDe.searchStations(query) }
    }

    /// Like `searchStations(_:near:)`; bahn.de's stations don't say which modes stop there, so it's
    /// only asked when no mode filter is set.
    public func searchStations(_ search: StationSearch, near location: Coordinate?) async throws -> [Station] {
        let askBahnDe = search.modes.isEmpty && !Self.isShortQuery(search.text)
        do {
            let stations = try await withFallback(deadline: .milliseconds(2500),
                { try await $0.searchStations(search, near: location) }, { try await $0.searchStations(search, near: location) })
            if !stations.isEmpty || bahnDe == nil || !askBahnDe { return stations }
        } catch {
            try Task.checkCancellation()
            guard let bahnDe, search.modes.isEmpty else { throw error }
            let stations = try await Self.withDeadline(.milliseconds(2500)) { try await bahnDe.searchStations(search.text) }
            return search.ordered(stations, near: location)
        }
        try Task.checkCancellation()
        guard let bahnDe else { return [] }
        let stations = try await Self.withDeadline(.milliseconds(2500)) { try await bahnDe.searchStations(search.text) }
        return search.ordered(stations, near: location)
    }

    static func isShortQuery(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count < 3
    }

    public func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        var page: JourneyPage
        if let cursor = query.cursor {
            // Pagination is tied to its provider. Never silently restart on another source.
            let provider = try provider(for: Self.cursorSource(cursor))
            var nextQuery = query
            nextQuery.cursor = Self.stripCursor(cursor, source: provider.source)
            page = try await provider.journeys(nextQuery)
        } else {
            // Providers resolve foreign and previously saved station IDs themselves.
            page = try await withFallback(deadline: .seconds(10),
                { try await $0.journeys(query) }, { try await $0.journeys(query) })
        }
        page.earlierCursor = page.earlierCursor.map { "\(page.source.rawValue):\($0)" }
        page.laterCursor = page.laterCursor.map { "\(page.source.rawValue):\($0)" }
        page.journeys = page.journeys.filter(query.allows)
        page.journeys = page.journeys.filter { journey in !journey.transitLegs.contains { Self.isFlixBus($0.line) } }
        let journeys = page.journeys
        async let coupled = coupledTrains(in: journeys, deadline: .seconds(3))
        // bahn.de's own names beat Transitous' generic ones for cross-border trains, like on boards.
        if let bahnDe {
            page.journeys = (try? await Self.withDeadline(.seconds(3)) { await bahnDe.correctingTrainNames(in: journeys) }) ?? journeys
        }
        page.journeys = Self.applying(await coupled, to: page.journeys)
        return page
    }

    /// Trains coupled to the journeys' legs not checked yet (see `TransitousProvider.coupledTrains(for:)`),
    /// keyed by `Leg.id`; none if Transitous isn't the primary or doesn't answer in time. A lookup that
    /// misses the deadline still finishes and is cached, so the journey's next refresh has it right away.
    public func coupledTrains(in journeys: [Journey], deadline: Duration) async -> [String: [Line.CoupledTrain]] {
        guard let transitous = primary as? TransitousProvider else { return [:] }
        let legs = journeys.flatMap(\.legs).filter { $0.line?.coupledTrains == nil }
        guard !legs.isEmpty else { return [:] }
        let lookup = Task { await transitous.coupledTrains(for: legs) }
        return (try? await Self.withDeadline(deadline) { await lookup.value }) ?? [:]
    }

    static func applying(_ coupled: [String: [Line.CoupledTrain]], to journeys: [Journey]) -> [Journey] {
        guard !coupled.isEmpty else { return journeys }
        return journeys.map { journey in
            var journey = journey
            for index in journey.legs.indices {
                if let trains = coupled[journey.legs[index].id] {
                    journey.legs[index].line?.coupledTrains = trains
                    journey.legs[index].line = journey.legs[index].line?.withoutSelfCoupling
                }
            }
            return journey
        }
    }

    public func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] {
        let entries = try await withFallback(deadline: .seconds(8),
                               { try await $0.board(kind, at: station, date: date, duration: duration, products: products) },
                               { try await $0.board(kind, at: station, date: date, duration: duration, products: products) })
        let filtered = entries.filter { !Self.isFlixBus($0.line) }
        // bahn.de's own names beat Transitous' generic ones for cross-border trains, and DB's live
        // times beat DELFI's forecasts (see `BahnDeClient.correctingFromBoard`); a slow bahn.de
        // mustn't hold up the board for long.
        guard let bahnDe else { return filtered }
        // Lines Transitous didn't know ("?") come from bahn.de's board too, in the same 3 s.
        return (try? await Self.withDeadline(.seconds(3)) {
            let named = filtered.contains { TransitousProvider.isUnknown($0.line) }
                ? await bahnDe.namingUnknownLines(filtered, at: station) : filtered
            return await bahnDe.correctingFromBoard(named, at: station)
        }) ?? filtered
    }

    /// FlixBus results are hidden from journey planning and departure boards entirely.
    private static func isFlixBus(_ line: Line?) -> Bool {
        line?.operatorName?.lowercased().contains("flixbus") ?? false
    }

    /// Trip IDs are only valid for their source, so no fallback here.
    public func trip(id: String) async throws -> Trip {
        try await primary.trip(id: id)
    }

    public func trip(id: String, source: DataSource) async throws -> Trip {
        try await provider(for: source).trip(id: id)
    }

    /// The run of a journey's leg. Transitous' trip IDs only last until the feed is next imported
    /// (DELFI renumbers its trips), so a saved journey's leg then gets a 404 for its train. Such a run
    /// is looked up again on the board at the leg's origin, as the same train leaving at the same planned
    /// time, and its new ID remembered while the app runs. The returned trip carries the new ID.
    public func trip(for leg: Leg) async throws -> Trip {
        guard let tripId = leg.tripId else { throw TransitError.notFound("Fahrt") }
        let id = await renumbered.id(for: tripId) ?? tripId
        do {
            return try await trip(id: id, source: leg.source)
        } catch let error as TransitError where error.isNotFound {
            guard leg.source == primary.source, let line = leg.line,
                  let entries = try? await primary.board(.departures, at: leg.origin,
                                                         date: leg.departure.planned.addingTimeInterval(-5 * 60),
                                                         duration: 15, products: [line.product]),
                  let current = Self.sameTrain(as: leg, in: entries)?.tripId, current != id else { throw error }
            await renumbered.remember(current, for: tripId)
            return try await trip(id: current, source: leg.source)
        }
    }

    /// The board entry for `leg`'s train: leaving at its planned time, by name or number.
    static func sameTrain(as leg: Leg, in entries: [BoardEntry]) -> BoardEntry? {
        guard let line = leg.line else { return nil }
        let names = Set([line.name, line.alternateName].compactMap { $0 }.map(Line.normalize))
        return entries.first { entry in
            guard entry.time.planned == leg.departure.planned else { return false }
            if [entry.line.name, entry.line.alternateName].compactMap({ $0 }).map(Line.normalize).contains(where: names.contains) {
                return true
            }
            return entry.line.product == line.product && line.dispatchNumber != nil
                && entry.line.dispatchNumber == line.dispatchNumber
        }
    }

    /// Trip IDs a feed import replaced: old ID → current one.
    actor RenumberedTrips {
        private var ids: [String: String] = [:]
        func id(for old: String) -> String? { ids[old] }
        func remember(_ current: String, for old: String) { ids[old] = current }
    }

    private func provider(for source: DataSource?) throws -> any TransitProvider {
        if source == primary.source { return primary }
        if let fallback, source == fallback.source { return fallback }
        throw TransitError.invalidInput("Diese Datenquelle ist nicht mehr verfügbar. Bitte die Verbindung neu suchen.")
    }

    static func cursorSource(_ cursor: String) -> DataSource? {
        guard let prefix = cursor.split(separator: ":", maxSplits: 1).first else { return nil }
        return DataSource(rawValue: String(prefix))
    }

    static func stripCursor(_ cursor: String, source: DataSource) -> String? {
        let prefix = source.rawValue + ":"
        guard cursor.hasPrefix(prefix) else { return nil }
        return String(cursor.dropFirst(prefix.count))
    }
}

/// The first of `operation`'s result, the deadline and the caller's cancellation wins
/// (`CombinedProvider.withDeadline`); the others are cancelled and ignored.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var outcome: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func start(_ continuation: CheckedContinuation<T, Error>, deadline: Duration,
               operation: @escaping @Sendable () async throws -> T) {
        lock.lock()
        // Cancelled before it started.
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        tasks = [
            Task { [self] in
                do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
            },
            Task { [self] in
                try? await Task.sleep(for: deadline)
                finish(.failure(TransitError.timeout))
            },
        ]
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = continuation
        self.continuation = nil
        let tasks = tasks
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
