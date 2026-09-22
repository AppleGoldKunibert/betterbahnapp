import Foundation

public enum Product: String, Codable, Sendable, CaseIterable, Hashable {
    case highSpeed      // ICE, TGV, ...
    case longDistance   // IC, EC, ...
    case regionalExpress
    case regional
    case suburban
    case subway
    case tram
    case bus
    case coach          // long-distance bus
    case ferry
    case other

    public var isTrain: Bool {
        switch self {
        case .highSpeed, .longDistance, .regionalExpress, .regional, .suburban: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .highSpeed: "ICE / Hochgeschwindigkeit"
        case .longDistance: "IC / EC"
        case .regionalExpress: "RE"
        case .regional: "RB"
        case .suburban: "S-Bahn"
        case .subway: "U-Bahn"
        case .tram: "Tram"
        case .bus: "Bus"
        case .coach: "Fernbus"
        case .ferry: "Fähre"
        case .other: "Sonstige"
        }
    }
}

public struct Line: Codable, Sendable, Hashable {
    /// Human readable, e.g. "ICE 423" or "RE 5".
    public var name: String
    /// Train number, e.g. "423".
    public var number: String?
    public var product: Product
    public var operatorName: String?
    /// Some international trains are carried under two names by separate GTFS feeds Transitous
    /// merges (e.g. an ÖBB "RJ 177" that Deutsche Bahn's own feed lists as "ICE 177") — one of them
    /// usually without realtime data. Set when a duplicate was found and merged away (see
    /// `TransitousProvider.board`), so callers like Träwelling check-in can still try that name too.
    public var alternateName: String?
    /// The run's own train number where it differs from `number` (a regional "RE3" is line 3 but run
    /// 3307) – what DB's dispatching feed knows the train by.
    public var tripNumber: String?

    /// The number to look this train up by in DB's own feed.
    public var dispatchNumber: String? { tripNumber ?? number }

    public init(name: String, number: String?, product: Product, operatorName: String?, alternateName: String? = nil,
                tripNumber: String? = nil) {
        self.tripNumber = tripNumber
        self.name = name
        self.number = number
        self.product = product
        self.operatorName = operatorName
        self.alternateName = alternateName
    }

    /// "ICE423", "ice 423" and "ICE  423" all normalize to "ice423".
    public static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// A scheduled + realtime point in time.
public struct TimeInfo: Codable, Sendable, Hashable {
    public var planned: Date
    public var actual: Date?

    public init(planned: Date, actual: Date?) {
        self.planned = planned
        self.actual = actual
    }

    public var best: Date { actual ?? planned }
    public var delayMinutes: Int? {
        guard let actual else { return nil }
        return Int((actual.timeIntervalSince(planned) / 60).rounded())
    }
}

public struct PlatformInfo: Codable, Sendable, Hashable {
    public var planned: String?
    public var actual: String?

    public init(planned: String?, actual: String?) {
        self.planned = planned
        self.actual = actual
    }

    public var best: String? { actual ?? planned }
    public var hasChanged: Bool {
        guard let planned, let actual else { return false }
        return planned != actual
    }
}

public struct Stopover: Codable, Sendable, Hashable, Identifiable {
    public var id: String { station.id + (arrival?.planned.description ?? departure?.planned.description ?? "") }
    public var station: Station
    public var arrival: TimeInfo?
    public var departure: TimeInfo?
    public var arrivalPlatform: PlatformInfo?
    public var departurePlatform: PlatformInfo?
    public var cancelled: Bool
    /// Whether passengers may actually board/alight here ("Nur Einstieg" / "Nur Ausstieg").
    public var access: StopAccess
    /// An unscheduled stop the train additionally picked up today ("Zusatzhalt"), not part of its
    /// regular timetable — only `BahnExpertClient` knows about these, see `inserting(_:into:)`.
    public var isAdditional: Bool

    public init(station: Station, arrival: TimeInfo?, departure: TimeInfo?,
                arrivalPlatform: PlatformInfo?, departurePlatform: PlatformInfo?, cancelled: Bool,
                access: StopAccess = .normal, isAdditional: Bool = false) {
        self.station = station
        self.arrival = arrival
        self.departure = departure
        self.arrivalPlatform = arrivalPlatform
        self.departurePlatform = departurePlatform
        self.cancelled = cancelled
        self.access = access
        self.isAdditional = isAdditional
    }

    enum CodingKeys: String, CodingKey {
        case station, arrival, departure, arrivalPlatform, departurePlatform, cancelled, access, isAdditional
    }

    /// Custom-decoded so journeys cached to disk before `access`/`isAdditional` existed still load,
    /// defaulting to `.normal`/`false`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        station = try c.decode(Station.self, forKey: .station)
        arrival = try c.decodeIfPresent(TimeInfo.self, forKey: .arrival)
        departure = try c.decodeIfPresent(TimeInfo.self, forKey: .departure)
        arrivalPlatform = try c.decodeIfPresent(PlatformInfo.self, forKey: .arrivalPlatform)
        departurePlatform = try c.decodeIfPresent(PlatformInfo.self, forKey: .departurePlatform)
        cancelled = try c.decode(Bool.self, forKey: .cancelled)
        access = try c.decodeIfPresent(StopAccess.self, forKey: .access) ?? .normal
        isAdditional = try c.decodeIfPresent(Bool.self, forKey: .isAdditional) ?? false
    }
}

public struct Leg: Codable, Sendable, Hashable, Identifiable {
    public var id: String { (tripId ?? "walk") + origin.id + departure.planned.description }
    public var origin: Station
    public var destination: Station
    public var departure: TimeInfo
    public var arrival: TimeInfo
    public var departurePlatform: PlatformInfo?
    public var arrivalPlatform: PlatformInfo?
    public var tripId: String?
    public var line: Line?
    public var direction: String?
    public var isWalking: Bool
    public var cancelled: Bool
    /// Intermediate stops including origin and destination, if loaded.
    public var stopovers: [Stopover]
    public var remarks: [String]
    public var source: DataSource
    /// Track geometry of the leg, if known.
    public var geometry: [Coordinate]?

    public init(origin: Station, destination: Station, departure: TimeInfo, arrival: TimeInfo,
                departurePlatform: PlatformInfo?, arrivalPlatform: PlatformInfo?, tripId: String?,
                line: Line?, direction: String?, isWalking: Bool, cancelled: Bool,
                stopovers: [Stopover], remarks: [String], source: DataSource, geometry: [Coordinate]? = nil) {
        self.geometry = geometry
        self.origin = origin
        self.destination = destination
        self.departure = departure
        self.arrival = arrival
        self.departurePlatform = departurePlatform
        self.arrivalPlatform = arrivalPlatform
        self.tripId = tripId
        self.line = line
        self.direction = direction
        self.isWalking = isWalking
        self.cancelled = cancelled
        self.stopovers = stopovers
        self.remarks = remarks
        self.source = source
    }
}

public struct Journey: Codable, Sendable, Hashable, Identifiable {
    public var id: String { legs.map(\.id).joined(separator: "|") }
    public var legs: [Leg]
    public var source: DataSource

    public init(legs: [Leg], source: DataSource) {
        self.legs = legs
        self.source = source
    }

    public var transitLegs: [Leg] { legs.filter { !$0.isWalking } }
    public var departure: TimeInfo? { legs.first?.departure }
    public var arrival: TimeInfo? { legs.last?.arrival }
    public var transfers: Int { max(0, transitLegs.count - 1) }
    public var duration: TimeInterval? {
        guard let d = departure, let a = arrival else { return nil }
        return a.best.timeIntervalSince(d.best)
    }
    public var isCancelled: Bool { legs.contains(where: \.cancelled) }

    /// Transfers where the next departure is before the previous arrival.
    public var brokenTransferIndices: [Int] {
        let transit = transitLegs
        guard transit.count > 1 else { return [] }
        return (1..<transit.count).filter { transit[$0].departure.best < transit[$0 - 1].arrival.best }
    }
}

public struct JourneyPage: Sendable {
    public var journeys: [Journey]
    public var earlierCursor: String?
    public var laterCursor: String?
    public var source: DataSource

    public init(journeys: [Journey], earlierCursor: String?, laterCursor: String?, source: DataSource) {
        self.journeys = journeys
        self.earlierCursor = earlierCursor
        self.laterCursor = laterCursor
        self.source = source
    }
}

public struct Trip: Codable, Sendable, Hashable {
    public var id: String
    public var line: Line?
    public var direction: String?
    public var stopovers: [Stopover]
    public var cancelled: Bool
    public var remarks: [String]
    public var source: DataSource

    public init(id: String, line: Line?, direction: String?, stopovers: [Stopover],
                cancelled: Bool, remarks: [String], source: DataSource) {
        self.id = id
        self.line = line
        self.direction = direction
        self.stopovers = stopovers
        self.cancelled = cancelled
        self.remarks = remarks
        self.source = source
    }

    public var origin: Station? { stopovers.first?.station }
    public var destination: Station? { stopovers.last?.station }
}
