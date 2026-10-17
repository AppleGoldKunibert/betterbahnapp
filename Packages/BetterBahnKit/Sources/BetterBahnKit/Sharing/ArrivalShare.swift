import Foundation

/// "Ankunft teilen" (#317): the last train of a journey, for the page the person picking you up opens in
/// any browser (`/s/<id>` on the `betterbahn` Worker). The Worker keeps it until `lifetimeAfterArrival`
/// after the arrival and asks bahn.de for the live times by `journeyId`; without one the page shows these
/// times. Only this train's data, never a location.
public struct ArrivalShare: Codable, Sendable, Equatable {
    /// "ICE 1095", "RE 3 (3307)".
    public var train: String
    public var product: Product
    /// The line's own color (S-Bahn Berlin …), as `0xRRGGBB`; else the page uses the product's.
    public var color: UInt32?
    /// bahn.de's journey ID of the train, for live times.
    public var journeyId: String?
    /// From where you board to where you get off.
    public var stops: [Stop]

    public struct Stop: Codable, Sendable, Equatable {
        public var name: String
        public var eva: String?
        public var arrival: Date?
        public var arrivalLive: Date?
        public var departure: Date?
        public var departureLive: Date?
        public var platform: String?
        public var platformLive: String?
        public var cancelled: Bool
    }

    /// How long the link works after the train arrives (the Worker uses the same value).
    public static let lifetimeAfterArrival: TimeInterval = 2 * 3600

    /// The train you arrive with: the journey's last leg that isn't a walk.
    public static func leg(of journey: Journey) -> Leg? { journey.transitLegs.last }

    /// Whether sharing `journey`'s arrival still makes sense at `now`.
    public static func canShare(_ journey: Journey, now: Date = .now) -> Bool {
        guard let leg = leg(of: journey) else { return false }
        return leg.arrival.best.addingTimeInterval(lifetimeAfterArrival) > now
    }

    /// `evaNumbers` fills in EVA numbers for stations that have none (by `Station.id`), so the Worker
    /// finds the stops in bahn.de's data.
    public init?(journey: Journey, journeyId: String? = nil, evaNumbers: [String: String] = [:]) {
        guard let leg = Self.leg(of: journey), let line = leg.line else { return nil }
        train = line.displayName
        product = line.product
        color = line.lineColorHex
        self.journeyId = journeyId
        let stopovers = leg.stopovers.count >= 2 ? leg.stopovers : [
            Stopover(station: leg.origin, arrival: nil, departure: leg.departure, arrivalPlatform: nil,
                     departurePlatform: leg.departurePlatform, cancelled: leg.cancelled),
            Stopover(station: leg.destination, arrival: leg.arrival, departure: nil, arrivalPlatform: leg.arrivalPlatform,
                     departurePlatform: nil, cancelled: leg.cancelled),
        ]
        stops = stopovers.enumerated().map { index, stop in
            let isLast = index == stopovers.count - 1
            // The destination's arrival platform, every other stop's departure platform.
            let platform = isLast ? (stop.arrivalPlatform ?? stop.departurePlatform) : (stop.departurePlatform ?? stop.arrivalPlatform)
            return Stop(name: stop.station.displayName, eva: stop.station.evaNumber ?? evaNumbers[stop.station.id],
                        arrival: stop.arrival?.planned, arrivalLive: stop.arrival?.actual,
                        departure: stop.departure?.planned, departureLive: stop.departure?.actual,
                        platform: platform?.planned, platformLive: platform?.actual,
                        cancelled: isLast ? stop.arrivalCancelled : stop.departureCancelled)
        }
    }

    /// The stations the Worker needs EVA numbers for: where you board and where you get off.
    public static func stationsNeedingEVA(in journey: Journey) -> [Station] {
        guard let leg = leg(of: journey) else { return [] }
        return [leg.origin, leg.destination].filter { $0.evaNumber == nil }
    }
}
