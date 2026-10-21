import Foundation
#if DEBUG && canImport(OSLog)
import OSLog
#endif

/// The class someone travels in (Settings → Reiseklasse), for DB's occupancy forecast (#399).
public enum TravelClass: String, Codable, CaseIterable, Sendable, Hashable {
    case first
    case second

    public var displayName: String {
        switch self {
        case .first: "1. Klasse"
        case .second: "2. Klasse"
        }
    }

    /// bahn.de's name for it in `auslastungsmeldungen`.
    var bahnDeKey: String {
        switch self {
        case .first: "KLASSE_1"
        case .second: "KLASSE_2"
        }
    }
}

/// How full DB expects a train to be ("Auslastung"), in DB's own levels. bahn.de's journey search sends
/// their texts along (`auslastungstexte`, as in db-vendo-client's `dbweb-journey.json` fixture): 0 "Keine
/// Auslastungsinformation verfügbar" (no forecast, never a level here), 1 "Geringe", 2 "Mittlere", 3 "Hohe",
/// 4 and 99 "Außergewöhnlich hohe Auslastung erwartet". At 4 DB suggests the other class, at 99 (both
/// classes) another connection.
public enum OccupancyLevel: Int, Codable, Sendable, Hashable, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    case exceptional = 4
    case exceptionalInBothClasses = 99

    /// DB's level ("stufe"); nil for 0 (no forecast) and anything unknown.
    init?(stufe: Int?) {
        guard let stufe, let level = OccupancyLevel(rawValue: stufe) else { return nil }
        self = level
    }

    public static func < (lhs: OccupancyLevel, rhs: OccupancyLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// DB's short text, e.g. "Hohe Auslastung erwartet".
    public var text: String {
        switch self {
        case .low: "Geringe Auslastung erwartet"
        case .medium: "Mittlere Auslastung erwartet"
        case .high: "Hohe Auslastung erwartet"
        case .exceptional, .exceptionalInBothClasses: "Außergewöhnlich hohe Auslastung erwartet"
        }
    }

    /// For a line naming the class: "1. Klasse: Auslastung gering".
    public var shortText: String {
        switch self {
        case .low: "gering"
        case .medium: "mittel"
        case .high: "hoch"
        case .exceptional, .exceptionalInBothClasses: "außergewöhnlich hoch"
        }
    }

    /// Figures as on DB's own pages: one for low, two for medium, three from high on.
    public var symbolName: String {
        switch self {
        case .low: "person.fill"
        case .medium: "person.2.fill"
        case .high, .exceptional, .exceptionalInBothClasses: "person.3.fill"
        }
    }

    /// Exceptionally high: DB asks travellers without a ticket to pick another train.
    public var isExceptional: Bool { self >= .exceptional }
}

/// DB's occupancy forecast for a ride: per class, the highest level from boarding up to the exit.
public struct OccupancyForecast: Sendable, Hashable {
    public var levels: [TravelClass: OccupancyLevel]

    public init(levels: [TravelClass: OccupancyLevel]) {
        self.levels = levels
    }

    public func level(for travelClass: TravelClass) -> OccupancyLevel? { levels[travelClass] }

    /// The other classes DB has a forecast for, to show beside the one travelled in.
    public func otherLevels(than travelClass: TravelClass) -> [(travelClass: TravelClass, level: OccupancyLevel)] {
        TravelClass.allCases.filter { $0 != travelClass }.compactMap { other in levels[other].map { (other, $0) } }
    }

    /// The highest level over several rides (a journey's legs) in `travelClass`.
    public static func highest(_ forecasts: [OccupancyForecast?], in travelClass: TravelClass) -> OccupancyLevel? {
        forecasts.compactMap { $0?.level(for: travelClass) }.max()
    }

    /// Per class, the highest level of `stops`. A stop's level is for the train leaving it, so the stops
    /// passed in end before the exit: what DB expects after it doesn't concern the ride. Nil without any.
    init?(stops: some Collection<JourneyStop>) {
        var levels: [TravelClass: OccupancyLevel] = [:]
        for stop in stops {
            for (travelClass, level) in stop.occupancy { levels[travelClass] = max(levels[travelClass] ?? level, level) }
        }
        guard !levels.isEmpty else { return nil }
        self.levels = levels
    }
}

extension BahnDeClient {
    /// DB's occupancy forecast for the part of `leg`'s train you ride (#399), from bahn.de's journey details
    /// (`auslastungsmeldungen` per stop). Nil when DB has none, or under the same conditions as
    /// `journeyStops(for:)`; shares its request and cache. A forecast doesn't change by the minute, so
    /// details up to `maxAge` old do: the live refresh's or the operators' answer is taken as it is.
    public func occupancy(for leg: Leg, maxAge: TimeInterval = BahnDeClient.occupancyMaxAge) async throws -> OccupancyForecast? {
        guard !leg.isWalking, let course = try await journeyCourse(for: leg, maxAge: maxAge) else { return nil }
        return Self.occupancy(of: leg, stops: course.stops)
    }

    /// The forecast for `leg` only if bahn.de's journey details are already cached (opened before, or a
    /// saved journey's refresh): for search results, which must never ask bahn.de once per result.
    public func cachedOccupancy(for leg: Leg) async -> OccupancyForecast? {
        guard !leg.isWalking,
              let course = await cachedJourneyCourse(line: leg.line, station: leg.origin, plannedDeparture: leg.departure.planned,
                                                     maxAge: Self.occupancyMaxAge)
        else { return nil }
        return Self.occupancy(of: leg, stops: course.stops)
    }

    /// The forecast for `trip`'s train from `boarding` up to `exit` (each nil: from its first stop / to its
    /// last). Nil when a picked stop isn't found in bahn.de's stops.
    public func occupancy(for trip: Trip, boarding: Stopover? = nil, exit: Stopover? = nil) async throws -> OccupancyForecast? {
        guard let first = trip.stopovers.first(where: { $0.departure != nil }), let departure = first.departure,
              let course = try await journeyCourse(line: trip.line, station: first.station, plannedDeparture: departure.planned,
                                                   maxAge: Self.occupancyMaxAge)
        else { return nil }
        return Self.occupancy(in: course.stops, boarding: boarding, exit: exit)
    }

    /// How old bahn.de's journey details may be for showing the forecast.
    public static let occupancyMaxAge: TimeInterval = 30 * 60

    static func occupancy(of leg: Leg, stops: [JourneyStop]) -> OccupancyForecast? {
        guard let ride = legRange(of: leg, in: stops) else { return nil }
        return OccupancyForecast(stops: stops[ride.lowerBound..<ride.upperBound])
    }

    static func occupancy(in stops: [JourneyStop], boarding: Stopover?, exit: Stopover?) -> OccupancyForecast? {
        var start = 0, end = stops.count - 1
        if let boarding {
            guard let planned = boarding.departure?.planned,
                  let index = stops.firstIndex(where: { isAt($0, boarding.station, planned: planned, side: \.departure) })
            else { return nil }
            start = index
        }
        if let exit {
            guard let planned = exit.arrival?.planned,
                  let index = stops.indices.last(where: { $0 > start && isAt(stops[$0], exit.station, planned: planned, side: \.arrival) })
            else { return nil }
            end = index
        }
        guard start < end else { return nil }
        return OccupancyForecast(stops: stops[start..<end])
    }

    /// Each class's level at a stop of bahn.de's journey details; level 0 (no forecast) is left out.
    static func occupancy(_ entries: [JourneyDetails.Stop.Occupancy]?) -> [TravelClass: OccupancyLevel] {
        var levels: [TravelClass: OccupancyLevel] = [:]
        for entry in entries ?? [] {
            guard let travelClass = TravelClass.allCases.first(where: { $0.bahnDeKey == entry.klasse }),
                  let level = OccupancyLevel(stufe: entry.stufe) else { continue }
            levels[travelClass] = level
        }
        return levels
    }

    /// Logs what bahn.de sent per stop, in DEBUG builds only, to check the field in the app (#399):
    /// "ICE 101: Berlin Hbf 1:0 2:0, Berlin-Wannsee 1:1 2:1, …", "–" for a stop without any entry.
    static func logOccupancy(of details: JourneyDetails) {
        #if DEBUG && canImport(OSLog)
        let stops = details.halte.map { stop in
            let entries = (stop.auslastungsmeldungen ?? []).map { entry in
                "\(entry.klasse?.replacingOccurrences(of: "KLASSE_", with: "") ?? "?"):\(entry.stufe.map(String.init) ?? "?")"
            }
            return "\(stop.name) \(entries.isEmpty ? "–" : entries.joined(separator: " "))"
        }
        Self.occupancyLog.info("\(details.zugName ?? "?", privacy: .public): \(stops.joined(separator: ", "), privacy: .public)")
        #endif
    }

    #if DEBUG && canImport(OSLog)
    private static let occupancyLog = Logger(subsystem: "de.goldkunibert.BetterBahn", category: "occupancy")
    #endif
}
