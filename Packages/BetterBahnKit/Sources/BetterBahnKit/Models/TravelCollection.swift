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

/// The collection ("Sammlung", #384): special liveries, series, trainsets and big stations the user
/// has travelled with or been at, from the same rides as the travel map (saved journeys and Träwelling
/// check-ins). Trains only count where a formation is remembered for a saved journey: liveries and
/// trainsets need the Tz that ran, series also count the planned series; stations count for boarding,
/// alighting and changing there.
public struct TravelCollection: Sendable, Hashable {
    public enum Category: String, CaseIterable, Sendable, Hashable, Identifiable {
        case liveries, series, trainsets, stations

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .liveries: String(kit: "Sonderlackierungen")
            case .series: String(kit: "Baureihen")
            case .trainsets: String(kit: "Triebzüge")
            case .stations: String(kit: "Große Bahnhöfe")
            }
        }
    }

    /// One train ride (a leg) and the trainsets seen on it, if remembered.
    public struct Ride: Sendable, Hashable {
        public var leg: Leg
        public var formation: TrainFormation?
        /// The journey the leg belongs to, opened from the collection.
        public var journey: Journey?

        public init(leg: Leg, formation: TrainFormation? = nil, journey: Journey? = nil) {
            self.leg = leg
            self.formation = formation
            self.journey = journey
        }
    }

    /// When and on which ride an item was collected.
    public struct Sighting: Sendable, Hashable {
        public var date: Date
        /// "ICE 597"; nil when the feed has no name for the train.
        public var train: String?
        public var from: String
        public var to: String
        /// The journey of the ride, if known.
        public var journey: Journey?
    }

    public struct Item: Sendable, Hashable, Identifiable {
        /// Stable across versions, e.g. "trainset:9018"; kept to tell newly collected items apart.
        public var id: String
        public var category: Category
        /// "Regenbogen", "ICE 4", "Tz 9018", "Berlin Hbf".
        public var title: String
        /// "Tz 304", "Freiburg im Breisgau", "Großer Bahnhof"; nil for a trainset without a name.
        public var subtitle: String?
        /// A trainset's series ("ICE 4", `TravelCollection.series`, else its model or "Weitere") and length
        /// ("7-teilig", where a series has several), see `trainsetSeries`.
        public var series: String?
        public var variant: String?
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

    /// One series of the trainsets ("ICE 4"), split by length where it has several.
    public struct TrainsetSeries: Sendable, Hashable, Identifiable {
        public var name: String
        public var variants: [TrainsetVariant]

        public var id: String { name }
        public var items: [Item] { variants.flatMap(\.items) }
        public var collected: Int { items.count(where: \.isCollected) }
        public var total: Int { items.count }
    }

    /// "7-teilig"; one with a nil name where the series isn't split.
    public struct TrainsetVariant: Sendable, Hashable, Identifiable {
        public var name: String?
        public var items: [Item]

        public var id: String { name ?? "" }
        /// The name, "Weitere" for the Tz outside the series' lengths.
        public var title: String { name ?? String(kit: "Weitere") }
        public var collected: Int { items.count(where: \.isCollected) }
        public var total: Int { items.count }
    }

    /// How the trainsets of one series (or length) are listed.
    public enum TrainsetOrder: String, CaseIterable, Sendable, Hashable, Identifiable {
        case number, mostRides, lastRidden, collectedFirst

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .number: String(kit: "Tz-Nummer")
            case .mostRides: String(kit: "Meiste Fahrten")
            case .lastRidden: String(kit: "Zuletzt gefahren")
            case .collectedFirst: String(kit: "Gesammelte zuerst")
            }
        }

        /// `items` (in Tz order) in this order; ties and the ones not collected keep the Tz order.
        public func sorted(_ items: [Item]) -> [Item] {
            let indexed = Array(items.enumerated())
            func by(_ less: (Item, Item) -> Bool?) -> [Item] {
                indexed.sorted { a, b in less(a.element, b.element) ?? (a.offset < b.offset) }.map(\.element)
            }
            switch self {
            case .number:
                return items
            case .mostRides:
                return by { a, b in a.sightings.count == b.sightings.count ? nil : a.sightings.count > b.sightings.count }
            case .lastRidden:
                return by { a, b in
                    switch (a.sightings.first?.date, b.sightings.first?.date) {
                    case let (x?, y?): x == y ? nil : x > y
                    case (_?, nil): true
                    case (nil, _?): false
                    case (nil, nil): nil
                    }
                }
            case .collectedFirst:
                return by { a, b in a.isCollected == b.isCollected ? nil : a.isCollected }
            }
        }
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
                  trainsetNames: TrainsetNames.byUnit, fleet: TrainsetFleet.all, dhid: StationNames.dhid(for:))
    }

    /// `dhid` finds a stop's DB station (the stations' DHIDs). Trainsets are every Tz of `fleet` plus the
    /// ones ridden outside it (retired, or not listed yet) that are long-distance or have a name.
    init(rides: [Ride], now: Date, stations: [BigStation], liveries: [Int: String], trainsetNames: [Int: String],
         fleet: [TrainsetFleet.Series], dhid: (Station) -> String?) {
        let rides = rides.filter { !$0.leg.cancelled && !$0.leg.isWalking && $0.leg.arrival.best <= now }
        var trainSightings: [String: [Sighting]] = [:]
        var stationSightings: [String: [Sighting]] = [:]
        /// The series of each Tz ridden, from its model; nil when not known.
        var unitSeries: [Int: String?] = [:]
        let bigStations = Set(stations.map(\.dhid))
        for ride in rides {
            let leg = ride.leg
            let train = YearReview.trainName(leg)
            let from = leg.origin.displayName, to = leg.destination.displayName
            let sighting = Sighting(date: leg.departure.planned, train: train, from: from, to: to, journey: ride.journey)
            // A number longer than any Tz is an IC 1 coach set that older versions remembered as an "ICE L"
            // ("IC450007" on IC 1189): neither a trainset nor that series.
            let units = (ride.formation?.isIC1 == true ? [] : ride.formation?.units ?? []).filter { ($0.number?.count ?? 0) <= 4 }
            var keys: Set<String> = []
            for unit in units {
                let model = unit.model.map(Self.seriesName(of:))
                if let model { keys.insert("series:\(model)") }
                if let number = unit.number.flatMap(Int.init) {
                    keys.insert("trainset:\(number)")
                    keys.insert("livery:\(number)")
                    if let model { unitSeries[number] = model } else if unitSeries[number] == nil { unitSeries[number] = .some(nil) }
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
            Item(id: "livery:\(number)", category: .liveries, title: livery, subtitle: String(kit: "Tz %@", number),
                 sightings: newestFirst(trainSightings["livery:\(number)"]))
        }
        let seriesItems = Self.series.map { name in
            Item(id: "series:\(name)", category: .series, title: name, subtitle: nil,
                 sightings: newestFirst(trainSightings["series:\(name)"]))
        }
        let trainsetItems = Self.trainsetItems(fleet: fleet, ridden: unitSeries, names: trainsetNames) { number in
            newestFirst(trainSightings["trainset:\(number)"])
        }
        let stationItems = stations.sorted { ($0.priceClass, $0.name) < ($1.priceClass, $1.name) }.map { station in
            Item(id: "station:\(station.dhid)", category: .stations, title: Station.displayName(for: station.name),
                 subtitle: station.priceClass == 1 ? String(kit: "Großer Bahnhof") : String(kit: "Mittlerer Bahnhof"),
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

    /// The trainsets by series (in `series` order, others after), then by length.
    public var trainsetSeries: [TrainsetSeries] {
        var result: [TrainsetSeries] = []
        for item in group(.trainsets)?.items ?? [] {
            let name = item.series ?? String(kit: "Weitere")
            if result.last?.name != name { result.append(TrainsetSeries(name: name, variants: [])) }
            let last = result.count - 1
            if let index = result[last].variants.firstIndex(where: { $0.name == item.variant }) {
                result[last].variants[index].items.append(item)
            } else {
                result[last].variants.append(TrainsetVariant(name: item.variant, items: [item]))
            }
        }
        return result
    }

    /// Collected trainsets without a name: before #521 only named ones were collected, so these are
    /// taken as seen once instead of all showing up as new.
    public var collectedUnnamedTrainsetIDs: Set<String> {
        Set((group(.trainsets)?.items ?? []).filter { $0.isCollected && $0.subtitle == nil }.map(\.id))
    }

    /// Every Tz of `fleet`, plus those `ridden` outside it whose series (from the model) is a long-distance
    /// one of `series` or that have a name; ordered by series, length and number.
    static func trainsetItems(fleet: [TrainsetFleet.Series], ridden: [Int: String?], names: [Int: String],
                              sightings: (Int) -> [Sighting]) -> [Item] {
        let index = TrainsetFleet.index(fleet)
        let fleetSeries = Set(fleet.map(\.name))
        // series → variant → numbers, in fleet order first.
        var placed: [(series: String?, variant: String?, numbers: [Int])] = fleet.flatMap { series in
            series.variants.map { (series: Optional(series.name), variant: $0.name, numbers: $0.numbers) }
        }
        for (number, model) in ridden {
            guard index[number] == nil else { continue }
            let isLongDistance = model.map { series.contains($0) || fleetSeries.contains($0) } ?? false
            guard isLongDistance || names[number] != nil else { continue }
            if let at = placed.firstIndex(where: { $0.series == model && $0.variant == nil }) {
                placed[at].numbers.append(number)
            } else {
                placed.append((series: model, variant: nil, numbers: [number]))
            }
        }
        let order = series + fleet.map(\.name).filter { !series.contains($0) }
        func rank(_ name: String?) -> (Int, String) {
            guard let name else { return (Int.max, "") }
            return (order.firstIndex(of: name) ?? order.count, name)
        }
        // Stable: variants keep the fleet's order within a series.
        let sorted = placed.enumerated().sorted { a, b in
            let ra = rank(a.element.series), rb = rank(b.element.series)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        return sorted.flatMap { entry in
            entry.numbers.sorted().map { number in
                Item(id: "trainset:\(number)", category: .trainsets, title: String(kit: "Tz %@", "\(number)"),
                     subtitle: names[number], series: entry.series, variant: entry.variant,
                     sightings: sightings(number))
            }
        }
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
