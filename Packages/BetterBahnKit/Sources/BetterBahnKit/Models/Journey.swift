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

    /// A line the feed didn't name ("?", e.g. an extra train DB added at short notice); a board names
    /// it after the other trains to its destination or bahn.de (`TransitousProvider.namingUnknownLines`).
    public var isUnknown: Bool {
        product == .other && name.trimmingCharacters(in: CharacterSet(charactersIn: "? ")).isEmpty
    }

    /// Another train coupled to this one for the whole stretch ridden, under its own number.
    public struct CoupledTrain: Codable, Sendable, Hashable {
        /// "ICE 940"
        public var name: String
        /// Where that train goes, which can be past the stretch ridden ("Düsseldorf Hbf").
        public var direction: String?
        /// Its own run, to show its stops.
        public var tripId: String?

        public init(name: String, direction: String?, tripId: String? = nil) {
            self.name = name
            self.direction = direction
            self.tripId = tripId
        }
    }

    /// Trains coupled to this one for the whole stretch ridden, each under its own number
    /// ("Doppeltraktion", e.g. ICE 950 that runs together with ICE 940 from Berlin to Hamm, where
    /// they split). Riding either is the same, so they are shown as one (`displayName`).
    public var coupledTrains: [CoupledTrain]?

    public var coupledNames: [String]? { coupledTrains?.map(\.name) }

    /// The numbers of the coupled trains ("940"), for bahn.de's coach sequence.
    public var coupledNumbers: [String] {
        (coupledTrains ?? []).compactMap { Self.trailingNumber($0.name) }
    }

    /// This train and the coupled ones whose own run is known, this one first, to switch between
    /// their stops. Empty when there is nothing to switch to.
    public func runs(ownDirection direction: String?, ownTripId tripId: String) -> [CoupledTrain] {
        let others = (coupledTrains ?? []).filter { $0.tripId != nil && $0.tripId != tripId }
        guard !others.isEmpty else { return [] }
        return [CoupledTrain(name: name, direction: direction, tripId: tripId)] + others
    }

    /// This train ridden as the coupled train `name` instead: that one's name and number lead, this
    /// one becomes a coupled train going `direction`.
    public func riding(_ train: CoupledTrain, ownDirection direction: String?, ownTripId: String? = nil) -> Line {
        guard let index = coupledTrains?.firstIndex(of: train) else { return self }
        var line = self
        var others = coupledTrains ?? []
        others[index] = CoupledTrain(name: name, direction: direction, tripId: ownTripId)
        line.coupledTrains = others
        line.name = train.name
        line.number = Self.trailingNumber(train.name)
        line.tripNumber = nil
        line.alternateName = nil
        return line
    }

    private static func trailingNumber(_ name: String) -> String? {
        guard let last = name.split(separator: " ").last, last.allSatisfy(\.isNumber) else { return nil }
        return String(last)
    }

    /// Whether `name` is this train under another brand rather than another train: the same number
    /// ("ICE 177" for the Railjet "RJ 177", which Transitous has from both DB's and ÖBB's feed).
    public func isSameTrain(as name: String) -> Bool {
        guard let own = number ?? Self.trailingNumber(self.name), let other = Self.trailingNumber(name) else { return false }
        return own.drop(while: { $0 == "0" }) == other.drop(while: { $0 == "0" })
    }

    /// `coupledTrains` without entries that are this very train under another name (see `isSameTrain(as:)`),
    /// nil when none is left.
    public var withoutSelfCoupling: Line {
        guard let coupledTrains, coupledTrains.contains(where: { isSameTrain(as: $0.name) }) else { return self }
        var line = self
        let others = coupledTrains.filter { !isSameTrain(as: $0.name) }
        line.coupledTrains = others.isEmpty ? nil : others
        return line
    }

    /// The number to look this train up by in DB's own feed.
    public var dispatchNumber: String? { tripNumber ?? number }

    /// An S-Bahn's name with its run number, the way DB names an RE: "S 8 (37856)". Only for the train
    /// view, the numbers are long. Other trains keep `name` (an ICE's name is its number already).
    public var nameWithTripNumber: String {
        guard product == .suburban, let tripNumber, tripNumber != number,
              !name.split(whereSeparator: { !$0.isNumber }).contains(where: { $0 == tripNumber }) else { return name }
        return "\(name) (\(tripNumber))"
    }

    /// `name`, or for coupled trains every train's name, lowest number first: "ICE 940 / 950".
    public var displayName: String {
        guard let coupledNames, !coupledNames.isEmpty else { return name }
        let names = ([name] + coupledNames).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let categories = Set(names.map(Self.category))
        guard categories.count == 1, let category = categories.first, !category.isEmpty else {
            return names.joined(separator: " / ")
        }
        return category + " " + names.map { $0.dropFirst(category.count).trimmingCharacters(in: .whitespaces) }
            .joined(separator: " / ")
    }

    /// Every name this train goes by: its own, the codeshare's and those of the coupled trains.
    public var allNames: [String] {
        [name] + [alternateName].compactMap { $0 } + (coupledNames ?? [])
    }

    /// "ICE" for "ICE 940"; "" when the name doesn't end in a number.
    private static func category(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last, last.allSatisfy(\.isNumber) else { return "" }
        return parts.dropLast().joined(separator: " ")
    }

    public init(name: String, number: String?, product: Product, operatorName: String?, alternateName: String? = nil,
                tripNumber: String? = nil, coupledTrains: [CoupledTrain]? = nil) {
        self.coupledTrains = coupledTrains
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
    /// Where the platform came from, when not from the train's own data (which may be live).
    public var source: Source?

    public enum Source: String, Codable, Sendable, Hashable {
        /// The Czech national timetable (CZPTT, from Správa železnic), taken over for a train another
        /// feed has no platforms for in Czechia: planned only, a change at short notice won't show.
        case czechTimetable
    }

    /// Blank values count as none: bahn.de reports `"gleis": ""` at stations it has no platform for
    /// (e.g. in Czechia), which showed as a "Gleis" badge without a number.
    public init(planned: String?, actual: String?, source: Source? = nil) {
        self.planned = Self.nonBlank(planned)
        self.actual = Self.nonBlank(actual)
        self.source = source
    }

    /// Also drops the blank platforms journeys saved before kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(planned: try c.decodeIfPresent(String.self, forKey: .planned),
                  actual: try c.decodeIfPresent(String.self, forKey: .actual),
                  source: try? c.decodeIfPresent(Source.self, forKey: .source))
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
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
    /// Kept apart because DB cancels either side on its own — a train cut short ends with an
    /// arrival that still happens but a cancelled departure, and one starting late the other way round.
    public var arrivalCancelled: Bool
    public var departureCancelled: Bool
    /// Whether passengers may actually board/alight here ("Nur Einstieg" / "Nur Ausstieg").
    public var access: StopAccess
    /// An unscheduled stop the train additionally picked up today ("Zusatzhalt"), not part of its
    /// regular timetable — only `BahnDeClient.journeyStops` knows about these, see `inserting(_:into:)`.
    public var isAdditional: Bool

    public init(station: Station, arrival: TimeInfo?, departure: TimeInfo?,
                arrivalPlatform: PlatformInfo?, departurePlatform: PlatformInfo?, cancelled: Bool,
                access: StopAccess = .normal, isAdditional: Bool = false) {
        self.station = station
        self.arrival = arrival
        self.departure = departure
        self.arrivalPlatform = arrivalPlatform
        self.departurePlatform = departurePlatform
        self.arrivalCancelled = cancelled
        self.departureCancelled = cancelled
        self.access = access
        self.isAdditional = isAdditional
    }

    /// The whole stop is out: every side it actually has (arrival and/or departure) is cancelled.
    /// Setting it cancels (or restores) both sides.
    public var cancelled: Bool {
        get {
            guard arrival != nil || departure != nil else { return arrivalCancelled && departureCancelled }
            return (arrival == nil || arrivalCancelled) && (departure == nil || departureCancelled)
        }
        set {
            arrivalCancelled = newValue
            departureCancelled = newValue
        }
    }

    enum CodingKeys: String, CodingKey {
        case station, arrival, departure, arrivalPlatform, departurePlatform, cancelled, arrivalCancelled,
             departureCancelled, access, isAdditional
    }

    /// Custom-decoded so journeys cached to disk before `access`/`isAdditional`/the per-side
    /// cancellation existed still load, defaulting to `.normal`/`false`/the old single `cancelled`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        station = try c.decode(Station.self, forKey: .station)
        arrival = try c.decodeIfPresent(TimeInfo.self, forKey: .arrival)
        departure = try c.decodeIfPresent(TimeInfo.self, forKey: .departure)
        arrivalPlatform = try c.decodeIfPresent(PlatformInfo.self, forKey: .arrivalPlatform)
        departurePlatform = try c.decodeIfPresent(PlatformInfo.self, forKey: .departurePlatform)
        let cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        arrivalCancelled = try c.decodeIfPresent(Bool.self, forKey: .arrivalCancelled) ?? cancelled
        departureCancelled = try c.decodeIfPresent(Bool.self, forKey: .departureCancelled) ?? cancelled
        access = try c.decodeIfPresent(StopAccess.self, forKey: .access) ?? .normal
        isAdditional = try c.decodeIfPresent(Bool.self, forKey: .isAdditional) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(station, forKey: .station)
        try c.encodeIfPresent(arrival, forKey: .arrival)
        try c.encodeIfPresent(departure, forKey: .departure)
        try c.encodeIfPresent(arrivalPlatform, forKey: .arrivalPlatform)
        try c.encodeIfPresent(departurePlatform, forKey: .departurePlatform)
        // Still written so an older build reading the same file keeps decoding it.
        try c.encode(cancelled, forKey: .cancelled)
        try c.encode(arrivalCancelled, forKey: .arrivalCancelled)
        try c.encode(departureCancelled, forKey: .departureCancelled)
        try c.encode(access, forKey: .access)
        try c.encode(isAdditional, forKey: .isAdditional)
    }
}

extension Array where Element == Journey {
    /// Drops journeys whose `id` already came earlier: a list showing both (e.g. in a `LazyVStack`)
    /// renders only one of them and leaves an empty gap for the other.
    public func removingDuplicateIDs() -> [Journey] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }

    /// Drops journeys taking the very same trains at the same times as another one, only from another
    /// feed: Transitous routes RJ 385 Berlin → Praha over DB's copy ("ICE 385", named "RJ 385" by bahn.de)
    /// and over Rejseplanen's, and once their stops are filled in from each other they read alike. The
    /// copy with more live data, then more stops and platforms, stays, in the place of the first.
    public func removingSameTrainDuplicates() -> [Journey] {
        var result: [Journey] = []
        for journey in self {
            if let index = result.firstIndex(where: { $0.isSameRide(as: journey) }) {
                if journey.completeness > result[index].completeness { result[index] = journey }
            } else {
                result.append(journey)
            }
        }
        return result
    }
}

extension Journey {
    /// The same trains (by number) between the same places at the same planned times, walks aside.
    func isSameRide(as other: Journey) -> Bool {
        let legs = transitLegs, otherLegs = other.transitLegs
        guard !legs.isEmpty, legs.count == otherLegs.count else { return false }
        return zip(legs, otherLegs).allSatisfy { a, b in
            guard let number = a.line?.number, number == b.line?.number, a.line?.product.isTrain == b.line?.product.isTrain
            else { return false }
            return a.departure.planned == b.departure.planned && a.arrival.planned == b.arrival.planned
                && a.origin.isSamePlace(as: b.origin) && a.destination.isSamePlace(as: b.destination)
        }
    }

    /// How much a journey knows: live times first, then stops, then platforms.
    var completeness: (Int, Int, Int) {
        let legs = transitLegs
        let live = legs.filter { $0.departure.actual != nil || $0.arrival.actual != nil }.count
        let stops = legs.reduce(0) { $0 + $1.stopovers.count }
        let platforms = legs.reduce(0) { count, leg in
            count + (leg.departurePlatform?.best != nil ? 1 : 0) + (leg.arrivalPlatform?.best != nil ? 1 : 0)
                + leg.stopovers.filter { ($0.departurePlatform ?? $0.arrivalPlatform)?.best != nil }.count
        }
        return (live, stops, platforms)
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
    /// Delay reasons and notices from DB's own feed along this leg (see `TrainMessage`).
    public var messages: [TrainMessage]
    public var source: DataSource
    /// Track geometry of the leg, if known.
    public var geometry: [Coordinate]?

    public init(origin: Station, destination: Station, departure: TimeInfo, arrival: TimeInfo,
                departurePlatform: PlatformInfo?, arrivalPlatform: PlatformInfo?, tripId: String?,
                line: Line?, direction: String?, isWalking: Bool, cancelled: Bool,
                stopovers: [Stopover], remarks: [String], messages: [TrainMessage] = [], source: DataSource,
                geometry: [Coordinate]? = nil) {
        self.messages = messages
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

    enum CodingKeys: String, CodingKey {
        case origin, destination, departure, arrival, departurePlatform, arrivalPlatform, tripId, line, direction
        case isWalking, cancelled, stopovers, remarks, messages, source, geometry
    }

    /// Custom-decoded so journeys saved before `messages` existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(Station.self, forKey: .origin)
        destination = try c.decode(Station.self, forKey: .destination)
        departure = try c.decode(TimeInfo.self, forKey: .departure)
        arrival = try c.decode(TimeInfo.self, forKey: .arrival)
        departurePlatform = try c.decodeIfPresent(PlatformInfo.self, forKey: .departurePlatform)
        arrivalPlatform = try c.decodeIfPresent(PlatformInfo.self, forKey: .arrivalPlatform)
        tripId = try c.decodeIfPresent(String.self, forKey: .tripId)
        line = try c.decodeIfPresent(Line.self, forKey: .line)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        isWalking = try c.decode(Bool.self, forKey: .isWalking)
        cancelled = try c.decode(Bool.self, forKey: .cancelled)
        stopovers = try c.decode([Stopover].self, forKey: .stopovers)
        remarks = try c.decode([String].self, forKey: .remarks)
        messages = try c.decodeIfPresent([TrainMessage].self, forKey: .messages) ?? []
        source = try c.decode(DataSource.self, forKey: .source)
        geometry = try c.decodeIfPresent([Coordinate].self, forKey: .geometry)
    }
}

public struct Journey: Codable, Sendable, Hashable, Identifiable {
    /// The legs, plus where the journey ends: a leg's ID doesn't include where you get off, so Berlin →
    /// Dresden and Berlin → Praha on the same train would otherwise be one journey (and opening one
    /// showed the other one remembered from before).
    public var id: String { legs.map(\.id).joined(separator: "|") + ">" + (legs.last?.destination.id ?? "") }
    public var legs: [Leg]
    public var source: DataSource

    public init(legs: [Leg], source: DataSource) {
        self.legs = legs
        self.source = source
    }

    public var transitLegs: [Leg] { legs.filter { !$0.isWalking } }
    public var departure: TimeInfo? { legs.first?.departure }
    public var arrival: TimeInfo? { legs.last?.arrival }

    /// This journey as planned, with every actual time removed, so no delay shows at all: what a
    /// long-finished journey had saved is no longer live data (and older saves carry a made-up "+0").
    public func droppingActualTimes() -> Journey {
        func dropped(_ time: TimeInfo) -> TimeInfo { TimeInfo(planned: time.planned, actual: nil) }
        var journey = self
        for index in journey.legs.indices {
            var leg = journey.legs[index]
            leg.departure = dropped(leg.departure)
            leg.arrival = dropped(leg.arrival)
            for stop in leg.stopovers.indices {
                leg.stopovers[stop].arrival = leg.stopovers[stop].arrival.map(dropped)
                leg.stopovers[stop].departure = leg.stopovers[stop].departure.map(dropped)
            }
            journey.legs[index] = leg
        }
        return journey
    }
    public var transfers: Int { max(0, transitLegs.count - 1) }
    public var duration: TimeInterval? {
        guard let d = departure, let a = arrival else { return nil }
        return a.best.timeIntervalSince(d.best)
    }
    public var isCancelled: Bool { legs.contains(where: \.cancelled) }

    /// Where each leg sits on the journey's bar, in order and never overlapping: a late train arriving
    /// after the next leg's departure pushes that leg (and the ones after) back, as the next metro would
    /// be taken. RJ 175 +31 into Praha-Holešovice, then walk and metro C on their planned times, drew the
    /// train across the whole bar with the metro as a dot on top. Empty for a journey without legs.
    public var barSpans: [DateInterval] {
        var spans: [DateInterval] = []
        for leg in legs {
            let start = max(leg.departure.best, spans.last?.end ?? leg.departure.best)
            let length = max(leg.arrival.best.timeIntervalSince(leg.departure.best), 0)
            spans.append(DateInterval(start: start, duration: length))
        }
        return spans
    }

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
    /// Delay reasons and notices from DB's own feed along the whole trip (see `TrainMessage`).
    public var messages: [TrainMessage]
    public var source: DataSource
    /// Track geometry of the whole run, if known.
    public var geometry: [Coordinate]?

    public init(id: String, line: Line?, direction: String?, stopovers: [Stopover],
                cancelled: Bool, remarks: [String], messages: [TrainMessage] = [], source: DataSource,
                geometry: [Coordinate]? = nil) {
        self.geometry = geometry
        self.messages = messages
        self.id = id
        self.line = line
        self.direction = direction
        self.stopovers = stopovers
        self.cancelled = cancelled
        self.remarks = remarks
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, line, direction, stopovers, cancelled, remarks, messages, source, geometry
    }

    /// Custom-decoded so data saved before `messages` or `geometry` existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        line = try c.decodeIfPresent(Line.self, forKey: .line)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        stopovers = try c.decode([Stopover].self, forKey: .stopovers)
        cancelled = try c.decode(Bool.self, forKey: .cancelled)
        remarks = try c.decode([String].self, forKey: .remarks)
        messages = try c.decodeIfPresent([TrainMessage].self, forKey: .messages) ?? []
        source = try c.decode(DataSource.self, forKey: .source)
        geometry = try c.decodeIfPresent([Coordinate].self, forKey: .geometry)
    }

    public var origin: Station? { stopovers.first?.station }
    public var destination: Station? { stopovers.last?.station }
}

public extension Leg {
    /// "Düsseldorf Hbf / Köln Hbf" when coupled trains go on to different places, otherwise `direction`.
    var directionDescription: String? {
        var directions: [String] = []
        for direction in [direction] + (line?.coupledTrains ?? []).map(\.direction) {
            if let direction, !direction.isEmpty, !directions.contains(direction) { directions.append(direction) }
        }
        return directions.isEmpty ? nil : directions.joined(separator: " / ")
    }

    /// This leg ridden as one of its coupled trains (e.g. to check in under that train's number).
    func riding(_ train: Line.CoupledTrain) -> Leg {
        guard let line else { return self }
        var leg = self
        leg.line = line.riding(train, ownDirection: direction, ownTripId: tripId)
        leg.direction = train.direction ?? direction
        leg.tripId = train.tripId ?? tripId
        return leg
    }
}
