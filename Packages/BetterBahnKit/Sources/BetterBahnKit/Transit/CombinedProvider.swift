import Foundation

/// Uses db-rest first (best DB realtime data) and falls back to Transitous on errors.
/// After a db-rest failure it skips db-rest for `cooldown` seconds.
public final class CombinedProvider: TransitProvider {
    public let source = DataSource.dbRest
    public let primary: any TransitProvider
    public let fallback: any TransitProvider
    public let bahnDe: BahnDeClient?
    private let health: Health

    public init(primary: any TransitProvider = DBRestProvider(),
                fallback: any TransitProvider = TransitousProvider(),
                bahnDe: BahnDeClient? = BahnDeClient(),
                cooldown: TimeInterval = 120) {
        self.bahnDe = bahnDe
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

    /// Runs `work` against db-rest if healthy, otherwise (or on error / after `deadline`) against Transitous.
    private func withFallback<T: Sendable>(
        usePrimary: Bool = true,
        deadline: Duration = .seconds(8),
        _ primaryWork: @escaping @Sendable (any TransitProvider) async throws -> T,
        _ fallbackWork: @Sendable (any TransitProvider) async throws -> T
    ) async throws -> T {
        if usePrimary, await health.primaryAvailable {
            let primary = self.primary
            do {
                let result = try await Self.withDeadline(deadline) { try await primaryWork(primary) }
                await health.markOK()
                return result
            } catch {
                // The caller went away (e.g. user kept typing) – don't blame db-rest.
                if Task.isCancelled { throw CancellationError() }
                await health.markFailed()
            }
        }
        return try await fallbackWork(fallback)
    }

    static func withDeadline<T: Sendable>(_ deadline: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw TransitError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TransitError.timeout }
            return result
        }
    }

    /// bahn.de first (fast, DB names with EVA numbers), then db-rest/Transitous.
    public func searchStations(_ query: String) async throws -> [Station] {
        if let bahnDe = self.bahnDe,
           let stations = try? await Self.withDeadline(.milliseconds(2500), { try await bahnDe.searchStations(query) }),
           !stations.isEmpty {
            return stations
        }
        if Task.isCancelled { throw CancellationError() }
        return try await withFallback(deadline: .milliseconds(2500),
                                      { try await $0.searchStations(query) }, { try await $0.searchStations(query) })
    }

    public func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        let bothFromPrimary = query.from.source == primary.source && query.to.source == primary.source
        let cursorSource = query.cursor.flatMap(Self.cursorSource)
        let usePrimary = bothFromPrimary && cursorSource != .transitous
        var primaryQuery = query
        primaryQuery.cursor = query.cursor.flatMap { Self.stripCursor($0, source: primary.source) }
        var fallbackQuery = query
        fallbackQuery.cursor = query.cursor.flatMap { Self.stripCursor($0, source: .transitous) }
        let pQuery = primaryQuery, fQuery = fallbackQuery
        var page = try await withFallback(usePrimary: usePrimary, deadline: .seconds(10),
                                          { try await $0.journeys(pQuery) },
                                          { try await $0.journeys(fQuery) })
        page.earlierCursor = page.earlierCursor.map { "\(page.source.rawValue):\($0)" }
        page.laterCursor = page.laterCursor.map { "\(page.source.rawValue):\($0)" }
        return page
    }

    public func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int) async throws -> [BoardEntry] {
        try await withFallback(usePrimary: station.source == primary.source || station.evaNumber != nil, deadline: .seconds(8),
                               { try await $0.board(kind, at: station, date: date, duration: duration) },
                               { try await $0.board(kind, at: station, date: date, duration: duration) })
    }

    /// Trip IDs are only valid for their source, so no fallback here.
    public func trip(id: String) async throws -> Trip {
        try await primary.trip(id: id)
    }

    public func trip(id: String, source: DataSource) async throws -> Trip {
        source == .transitous ? try await fallback.trip(id: id) : try await primary.trip(id: id)
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
