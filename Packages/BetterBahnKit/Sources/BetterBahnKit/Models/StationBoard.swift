import Foundation

public enum BoardKind: String, Codable, Sendable, CaseIterable {
    case departures
    case arrivals
}

/// Whether passengers may board and/or alight at this stop.
public enum StopAccess: String, Codable, Sendable, Hashable {
    case normal
    /// Only alighting ("Nur Ausstieg" / kein Einstieg).
    case exitOnly
    /// Only boarding ("Nur Einstieg").
    case entryOnly
    /// Train passes without a passenger stop ("Durchfahrt").
    case passThrough

    public init(pickupAllowed: Bool, dropoffAllowed: Bool) {
        switch (pickupAllowed, dropoffAllowed) {
        case (true, true): self = .normal
        case (false, true): self = .exitOnly
        case (true, false): self = .entryOnly
        case (false, false): self = .passThrough
        }
    }
}

/// One row of a departure or arrival board.
public struct BoardEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { tripId + time.planned.description }
    public var kind: BoardKind
    public var tripId: String
    public var station: Station
    public var line: Line
    /// Departures: final destination. Arrivals: origin of the trip.
    public var otherEnd: String?
    public var time: TimeInfo
    public var platform: PlatformInfo
    public var cancelled: Bool
    /// True if the trip starts here (departures) / ends here (arrivals), if known.
    public var terminatesOrOriginatesHere: Bool?
    public var remarks: [String]
    public var access: StopAccess
    public var source: DataSource

    public init(kind: BoardKind, tripId: String, station: Station, line: Line, otherEnd: String?,
                time: TimeInfo, platform: PlatformInfo, cancelled: Bool,
                terminatesOrOriginatesHere: Bool?, remarks: [String], access: StopAccess = .normal, source: DataSource) {
        self.access = access
        self.kind = kind
        self.tripId = tripId
        self.station = station
        self.line = line
        self.otherEnd = otherEnd
        self.time = time
        self.platform = platform
        self.cancelled = cancelled
        self.terminatesOrOriginatesHere = terminatesOrOriginatesHere
        self.remarks = remarks
        self.source = source
    }
}
