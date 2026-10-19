import Foundation

/// The year in review ("Jahresrückblick", #319): one year's train rides boiled down to a few facts,
/// shown one per card. Built on the device from the rides the travel map draws (saved journeys and
/// Träwelling check-ins, deduplicated with `RideMatch`).
public struct YearReview: Sendable, Hashable {
    /// One train ride (a leg), with what the app knows about it beyond the leg itself.
    public struct Ride: Sendable, Hashable {
        public var leg: Leg
        /// Track length; from the route geometry, else the stops' coordinates, else the straight line.
        public var kilometers: Double
        /// Trainsets seen on the train (Tz, series), if remembered.
        public var formation: TrainFormation?

        public init(leg: Leg, geometry: [Coordinate]? = nil, formation: TrainFormation? = nil) {
            self.leg = leg
            self.formation = formation
            kilometers = Self.kilometers(of: leg, geometry: geometry)
        }

        static func kilometers(of leg: Leg, geometry: [Coordinate]?) -> Double {
            if let geometry, geometry.count > 1 { return Polyline.length(geometry) / 1000 }
            var points = [leg.origin.coordinate]
            points += leg.stopovers.map(\.station.coordinate)
            points.append(leg.destination.coordinate)
            let coordinates = points.compactMap { $0 }
            return Polyline.length(coordinates) / 1000
        }

        var hours: Double { max(0, leg.arrival.best.timeIntervalSince(leg.departure.best)) / 3600 }
    }

    /// A ranked entry: a name and how often it came up.
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public struct LongestRide: Sendable, Hashable {
        public var train: String?
        public var from: String
        public var to: String
        public var kilometers: Double
        public var hours: Double
        public var date: Date
    }

    public var year: Int
    public var rides: Int
    public var kilometers: Double
    public var hours: Double
    /// Rides with a realtime arrival; only these count for delay and punctuality.
    public var ridesWithDelayData: Int
    /// Arrival delays added up (early arrivals count as 0).
    public var delayMinutes: Int
    /// Share of `ridesWithDelayData` arriving less than 6 minutes late (DB's own definition), 0…1.
    public var punctuality: Double?
    public var mostDelayed: Entry?
    /// Train series ("ICE 4"), most ridden first.
    public var series: [Entry]
    /// Single trainsets ("Tz 9457 „Bundesrepublik Deutschland“"), only those ridden more than once.
    public var trainsets: [Entry]
    /// Stations boarded at or left at, most used first.
    public var stations: [Entry]
    /// Origin–destination pairs in either direction, most ridden first.
    public var routes: [Entry]
    public var trains: [Entry]
    public var longestRide: LongestRide?
    public var nightTrains: Int
    /// Countries ridden in, by name; the most visited first.
    public var countries: [String]
    /// Busiest month (1…12) and its rides.
    public var busiestMonth: Entry?
    public var activeDays: Int
    /// The year's CO₂ by train compared with car and plane (#386).
    public var co2: CO2Comparison

    /// How many entries the ranked lists keep.
    public static let listLength = 5
    /// A ride arriving this late or later counts as late, like in DB's punctuality figures.
    public static let lateMinutes = 6

    public var isEmpty: Bool { rides == 0 }

    /// The review of `year` from `rides`; rides departing in other years are left out.
    public init(year: Int, rides allRides: [Ride], calendar: Calendar = .current) {
        let rides = allRides.filter { calendar.component(.year, from: $0.leg.departure.planned) == year }
        self.year = year
        self.rides = rides.count
        kilometers = rides.reduce(0) { $0 + $1.kilometers }
        hours = rides.reduce(0) { $0 + $1.hours }

        let delays = rides.compactMap { ride in ride.leg.arrival.delayMinutes.map { (ride, max(0, $0)) } }
        ridesWithDelayData = delays.count
        delayMinutes = delays.reduce(0) { $0 + $1.1 }
        punctuality = delays.isEmpty ? nil
            : Double(delays.count(where: { $0.1 < Self.lateMinutes })) / Double(delays.count)
        mostDelayed = delays.filter { $0.1 >= Self.lateMinutes }.max { $0.1 < $1.1 }
            .map { Entry(name: Self.trainName($0.0.leg) ?? Self.route($0.0.leg), count: $0.1) }

        var seriesCounts: [String: Int] = [:], trainsetCounts: [String: Int] = [:]
        for ride in rides {
            let units = ride.formation?.units ?? []
            for model in Set(units.compactMap { TrainModel.name($0.model, unit: $0.number) }) {
                seriesCounts[model, default: 0] += 1
            }
            for unit in units {
                guard let number = unit.number else { continue }
                let name = unit.name.map { "Tz \(number) „\($0)“" } ?? "Tz \(number)"
                trainsetCounts[name, default: 0] += 1
            }
        }
        series = Self.ranked(seriesCounts)
        trainsets = Self.ranked(trainsetCounts.filter { $0.value > 1 })

        stations = Self.ranked(Self.counts(rides.flatMap { [$0.leg.origin.displayName, $0.leg.destination.displayName] }))
        // Either direction counts as the same route, named the way it was ridden more often.
        var routeCounts: [String: [String: Int]] = [:]
        for ride in rides {
            let ends = [ride.leg.origin.displayName, ride.leg.destination.displayName]
            guard ends[0] != ends[1] else { continue }
            routeCounts[ends.sorted().joined(separator: "|"), default: [:]][Self.route(ride.leg), default: 0] += 1
        }
        routes = Self.ranked(Dictionary(uniqueKeysWithValues: routeCounts.values.map { directions in
            let name = directions.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
            return (name, directions.values.reduce(0, +))
        }))
        trains = Self.ranked(Self.counts(rides.compactMap { Self.trainName($0.leg) }).filter { $0.value > 1 })

        longestRide = rides.max { $0.kilometers < $1.kilometers }.flatMap { ride in
            ride.kilometers > 0
                ? LongestRide(train: Self.trainName(ride.leg), from: ride.leg.origin.displayName,
                              to: ride.leg.destination.displayName, kilometers: ride.kilometers,
                              hours: ride.hours, date: ride.leg.departure.planned)
                : nil
        }
        nightTrains = rides.count(where: { $0.leg.line?.isNightTrain ?? false })

        var countryCounts: [String: Int] = [:]
        for ride in rides {
            let stops = [ride.leg.origin] + ride.leg.stopovers.map(\.station) + [ride.leg.destination]
            for code in Set(stops.compactMap(Self.countryCode)) { countryCounts[code, default: 0] += 1 }
        }
        countries = Self.ranked(countryCounts, limit: nil).map { Self.countryName($0.name) }

        busiestMonth = Self.ranked(Self.counts(rides.map { String(calendar.component(.month, from: $0.leg.departure.planned)) }),
                                   limit: 1).first
        activeDays = Set(rides.map { calendar.startOfDay(for: $0.leg.departure.planned) }).count
        co2 = CO2Comparison(rides: rides.map { ($0.leg, $0.kilometers) })
    }

    /// The years with at least one ride, newest first.
    public static func years(of legs: [Leg], calendar: Calendar = .current) -> [Int] {
        Set(legs.map { calendar.component(.year, from: $0.departure.planned) }).sorted(by: >)
    }

    /// The year the review is offered for on `date`: the running one in December, the one just
    /// ended in January, nil otherwise.
    public static func featuredYear(on date: Date, calendar: Calendar = .current) -> Int? {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year else { return nil }
        switch components.month {
        case 12: return year
        case 1: return year - 1
        default: return nil
        }
    }

    // MARK: Helpers

    static func trainName(_ leg: Leg) -> String? {
        guard let line = leg.line, !line.isUnknown else { return nil }
        let name = line.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func route(_ leg: Leg) -> String {
        "\(leg.origin.displayName) – \(leg.destination.displayName)"
    }

    static func counts(_ names: [String]) -> [String: Int] {
        names.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Most frequent first, ties by name so the order stays stable.
    static func ranked(_ counts: [String: Int], limit: Int? = listLength) -> [Entry] {
        let sorted = counts.map { Entry(name: $0.key, count: $0.value) }
            .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    /// A station's country (ISO code), from its EVA number (UIC country code) or the IFOPT/feed in its
    /// Transitous ID ("de-DELFI_de:11000:900003201", "be-sncb_8015458", "cz-CZPTT_czptt:stop:CZ:55659").
    static func countryCode(of station: Station) -> String? {
        if let code = TrainSearchCountry.code(eva: station.evaNumber) { return code }
        let id = station.id
        guard let underscore = id.firstIndex(of: "_") else { return TrainSearchCountry.code(eva: id) }
        let local = String(id[id.index(after: underscore)...])
        if let code = TrainSearchCountry.code(eva: local, ifopt: local.contains(":") ? local : nil) { return code }
        let feed = id[..<underscore].prefix { $0 != "-" }
        return feed.count == 2 && feed.allSatisfy(\.isLetter) ? feed.uppercased() : nil
    }

    static func countryName(_ code: String) -> String {
        TrainSearchCountry.all.first { $0.code == code }?.name
            ?? Locale(identifier: "de_DE").localizedString(forRegionCode: code) ?? code
    }
}
