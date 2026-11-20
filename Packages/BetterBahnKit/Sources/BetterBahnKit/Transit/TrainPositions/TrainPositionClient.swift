import Foundation

/// Where the app gets live train positions: our Worker with DB's RIS::Maps (`RISMapsClient`) first, bahn.jetzt
/// (`BahnJetztClient`) when the Worker doesn't answer or doesn't know the train. `TrainPosition.source` says which.
///
/// After the Worker failed (offline, no App Attest token, an error) it is left alone for `primaryCooldown`, so every
/// refresh in between goes straight to bahn.jetzt instead of waiting for the Worker first.
public struct TrainPositionClient: Sendable {
    public typealias RunningTrain = BahnJetztClient.RunningTrain
    public typealias RouteHint = BahnJetztClient.RouteHint

    public let primary: RISMapsClient?
    public let fallback: BahnJetztClient?
    let health: Health

    public static let primaryCooldown: TimeInterval = 60

    public init(primary: RISMapsClient? = RISMapsClient(), fallback: BahnJetztClient? = BahnJetztClient(),
                health: Health = .shared) {
        self.primary = primary
        self.fallback = fallback
        self.health = health
    }

    /// Whether a position can be looked up for this train at all (long-distance by number, regional by run number).
    public static func supports(_ line: Line?) -> Bool { BahnJetztClient.supports(line) }

    /// Live position of a leg's train.
    /// - Returns: nil while neither source has the train.
    /// - Throws: only when the Worker had nothing and bahn.jetzt failed (e.g. `TransitError.rateLimited`).
    public func position(for leg: Leg) async throws -> TrainPosition? {
        try await position(of: leg.line, plannedDeparture: leg.departure.planned, route: BahnJetztClient.routeHint(for: leg))
    }

    /// Live position of `line`'s run that departs (somewhere along its route) at `plannedDeparture`.
    /// - Parameter route: checked for regional trains (`BahnJetztClient.isPlausible`); nil skips the check.
    public func position(of line: Line?, plannedDeparture: Date, route: RouteHint? = nil) async throws -> TrainPosition? {
        guard Self.supports(line) else { return nil }
        if let snapshot = await primarySnapshot(),
           let position = BahnJetztClient.position(of: line, plannedDeparture: plannedDeparture, route: route, in: snapshot) {
            return position
        }
        return try await fallback?.position(of: line, plannedDeparture: plannedDeparture, route: route)
    }

    /// Every running train with a position: the Worker's list, or bahn.jetzt's when the Worker doesn't answer.
    public func runningTrains() async throws -> [RunningTrain] {
        if let snapshot = await primarySnapshot() { return BahnJetztClient.runningTrains(in: snapshot) }
        guard let fallback else { throw TransitError.http(status: 503, body: nil) }
        return try await fallback.runningTrains()
    }

    /// The Worker's list; nil when there is no Worker, it failed recently or fails now.
    func primarySnapshot() async -> BahnJetztClient.Snapshot? {
        guard let primary, await health.mayAsk() else { return nil }
        do {
            return try await primary.snapshot()
        } catch {
            await health.failed()
            return nil
        }
    }

    /// When the Worker may be asked again after it failed.
    public actor Health {
        public static let shared = Health()

        let cooldown: TimeInterval
        private var failedAt: Date?

        public init(cooldown: TimeInterval = TrainPositionClient.primaryCooldown) {
            self.cooldown = cooldown
        }

        func mayAsk(now: Date = .now) -> Bool {
            guard let failedAt else { return true }
            return now.timeIntervalSince(failedAt) >= cooldown
        }

        func failed(now: Date = .now) { failedAt = now }
    }
}
