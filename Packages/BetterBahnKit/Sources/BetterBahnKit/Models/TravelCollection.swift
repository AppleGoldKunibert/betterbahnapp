import Foundation

/// A station of the collection's "Große Bahnhöfe" (`BigStations`), keyed by its stop area's DHID.
public struct BigStation: Sendable, Hashable {
    public var dhid: String
    /// DB's name, e.g. "Berlin Hbf".
    public var name: String
    /// DB InfraGO's price class ("Preisklasse"), 1 for the biggest stations.
    public var priceClass: Int

    public init(dhid: String, name: String, priceClass: Int) {
        self.dhid = dhid
        self.name = name
        self.priceClass = priceClass
    }
}

/// The collection ("Sammlung", #384): special liveries, series, named trainsets and big stations the user
/// has travelled with or been at, from the same rides as the travel map (saved journeys and Träwelling
/// check-ins). Trains only count where the trainset that ran is known (a formation remembered for a saved
/// journey); stations count for boarding, alighting and changing there.
public struct TravelCollection: Sendable, Hashable {
    public enum Category: String, CaseIterable, Sendable, Hashable, Identifiable {
        case liveries, series, trainsets, stations

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .liveries: "Sonderlackierungen"
            case .series: "Baureihen"
            case .trainsets: "Triebzüge"
            case .stations: "Große Bahnhöfe"
            }
        }
    }

    /// One train ride (a leg) and the trainsets seen on it, if remembered.
    public struct Ride: Sendable, Hashable {
        public var leg: Leg
        public var formation: TrainFormation?

        public init(leg: Leg, formation: TrainFormation? = nil) {
            self.leg = leg
            self.formation = formation
        }
    }

    /// When and on which ride an item was collected.
    public struct Sighting: Sendable, Hashable {
        public var date: Date
        /// "ICE 597"; nil when the feed has no name for the train.
        public var train: String?
        public var from: String
        public var to: String
    }

    public struct Item: Sendable, Hashable, Identifiable {
        /// Stable across versions, e.g. "trainset:9018"; kept to tell newly collected items apart.
        public var id: String
        public var category: Category
        /// "Regenbogen", "ICE 4", "Tz 9018", "Berlin Hbf".
        public var title: String
        /// "Tz 304", "Freiburg im Breisgau", "Großer Bahnhof".
        public var subtitle: String?
        /// Newest first.
        public var sightings: [Sighting]

        public var isCollected: Bool { !sightings.isEmpty }
        public var firstSighting: Sighting? { sightings.last }
    }

    public struct Group: Sendable, Hashable, Identifiable {
        public var category: Category
        public var items: [Item]

        public var id: Category { category }
        public var collected: Int { items.count(where: \.isCollected) }
        public var total: Int { items.count }
    }

    public var groups: [Group]

    /// The series that can be collected, in this order; a remembered unit's model is matched by `seriesName(of:)`.
    public static let series = [
        "ICE 1", "ICE 2", "ICE 3", "ICE 3 Velaro", "ICE 3neo", "ICE 4", "ICE T", "ICE L", "IC 2 Twindexx", "IC 2 KISS",
    ]

    /// Arriving and leaving a station within this time is one visit (a change of trains), not two.
    static let visitGap: TimeInterval = 3 * 3600

    /// The collection from `rides`; those not yet arrived (`now`) or cancelled are left out.
    public init(rides: [Ride], now: Date = .now) {
        self.init(rides: rides, now: now, stations: BigStations.all, liveries: TrainsetLiveries.byUnit,
                  trainsetNames: TrainsetNames.byUnit, dhid: StationNames.dhid(for:))
    }

    /// `dhid` finds a stop's DB station (the stations' DHIDs).
    init(rides: [Ride], now: Date, stations: [BigStation], liveries: [Int: String], trainsetNames: [Int: String],
         dhid: (Station) -> String?) {
        let rides = rides.filter { !$0.leg.cancelled && !$0.leg.isWalking && $0.leg.arrival.best <= now }
        var trainSightings: [String: [Sighting]] = [:]
        var stationSightings: [String: [Sighting]] = [:]
        let bigStations = Set(stations.map(\.dhid))
        for ride in rides {
            let leg = ride.leg
            let train = YearReview.trainName(leg)
            let from = leg.origin.displayName, to = leg.destination.displayName
            let sighting = Sighting(date: leg.departure.planned, train: train, from: from, to: to)
            let units = ride.formation?.isIC1 == true ? [] : ride.formation?.units ?? []
            var keys: Set<String> = []
            for unit in units {
                if let model = unit.model.map(Self.seriesName(of:)) { keys.insert("series:\(model)") }
                if let number = unit.number.flatMap(Int.init) {
                    keys.insert("trainset:\(number)")
                    keys.insert("livery:\(number)")
                }
            }
            for key in keys { trainSightings[key, default: []].append(sighting) }
            if let station = dhid(leg.origin), bigStations.contains(station) {
                stationSightings[station, default: []].append(sighting)
            }
            if let station = dhid(leg.destination), bigStations.contains(station) {
                var arrival = sighting
                arrival.date = leg.arrival.planned
                stationSightings[station, default: []].append(arrival)
            }
        }

        func newestFirst(_ sightings: [Sighting]?) -> [Sighting] {
            (sightings ?? []).sorted { $0.date > $1.date }
        }

        let liveryItems = liveries.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map { number, livery in
            Item(id: "livery:\(number)", category: .liveries, title: livery, subtitle: "Tz \(number)",
                 sightings: newestFirst(trainSightings["livery:\(number)"]))
        }
        let seriesItems = Self.series.map { name in
            Item(id: "series:\(name)", category: .series, title: name, subtitle: nil,
                 sightings: newestFirst(trainSightings["series:\(name)"]))
        }
        let trainsetItems = trainsetNames.sorted { $0.key < $1.key }.map { number, name in
            Item(id: "trainset:\(number)", category: .trainsets, title: "Tz \(number)", subtitle: name,
                 sightings: newestFirst(trainSightings["trainset:\(number)"]))
        }
        let stationItems = stations.sorted { ($0.priceClass, $0.name) < ($1.priceClass, $1.name) }.map { station in
            Item(id: "station:\(station.dhid)", category: .stations, title: Station.displayName(for: station.name),
                 subtitle: station.priceClass == 1 ? "Großer Bahnhof" : "Mittlerer Bahnhof",
                 sightings: Self.visits(newestFirst(stationSightings[station.dhid])))
        }
        groups = [
            Group(category: .liveries, items: liveryItems),
            Group(category: .series, items: seriesItems),
            Group(category: .trainsets, items: trainsetItems),
            Group(category: .stations, items: stationItems),
        ]
    }

    public func group(_ category: Category) -> Group? {
        groups.first { $0.category == category }
    }

    /// The IDs of every collected item.
    public var collectedIDs: Set<String> {
        Set(groups.flatMap(\.items).filter(\.isCollected).map(\.id))
    }

    /// Items collected since the collection was last looked at (`seen`, the `collectedIDs` then); none the
    /// first time, so everything ridden before doesn't show up as new.
    public func newIDs(since seen: Set<String>?) -> Set<String> {
        guard let seen else { return [] }
        return collectedIDs.subtracting(seen)
    }

    /// The series a unit's model belongs to: "ICE 3neo" for "ICE 3neo Redesign", "ICE 4" for bahn.expert's
    /// "ICE 4 Lang (BR412)".
    static func seriesName(of model: String) -> String {
        var name = TrainTypeLookup.family(of: model)
        if name.hasSuffix(" Redesign") { name.removeLast(" Redesign".count) }
        return name
    }

    /// `sightings` (newest first) with an arrival and the next departure close after it merged into one visit.
    static func visits(_ sightings: [Sighting]) -> [Sighting] {
        var result: [Sighting] = []
        for sighting in sightings {
            if let last = result.last, last.date.timeIntervalSince(sighting.date) < visitGap {
                result[result.count - 1] = sighting
            } else {
                result.append(sighting)
            }
        }
        return result
    }
}
