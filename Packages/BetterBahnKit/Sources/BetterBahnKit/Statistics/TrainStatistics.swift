import Foundation

/// What the statistics server (`Cloudflare/stats`, `POST /train-stats`) knows about one train from its
/// finished runs of the last days: delays, cancellations, platform moves and the vehicles that ran instead of the planned ones
/// (#316). Every figure is an experience value, shown only from `minimumRuns` runs on.
public struct TrainStatistics: Sendable, Hashable, Decodable {
    /// Fewer runs say too little to show anything.
    public static let minimumRuns = 5
    /// A train counts as on time up to this many minutes late.
    public static let onTimeMinutes = 5

    public var category: String
    public var number: String
    /// How many days back the runs reach.
    public var days: Int
    public var runs: Int
    /// Runs that were cancelled altogether.
    public var cancelledRuns: Int
    /// Runs with a Wagenreihung that bahn.de compared with the day's schedule, and those that differed.
    public var formationRuns: Int
    public var unplannedRuns: Int
    /// The vehicles that ran in those, by series, most common first. A series planned for some days
    /// doesn't show up here: only a run that differs from its own day's schedule counts.
    public var vehicles: [VehicleShare]
    /// Per EVA number of a stop that was asked for.
    public var stops: [String: Stop]

    public init(category: String, number: String, days: Int = 30, runs: Int, cancelledRuns: Int = 0,
                formationRuns: Int = 0, unplannedRuns: Int = 0, vehicles: [VehicleShare] = [], stops: [String: Stop] = [:]) {
        self.category = category
        self.number = number
        self.days = days
        self.runs = runs
        self.cancelledRuns = cancelledRuns
        self.formationRuns = formationRuns
        self.unplannedRuns = unplannedRuns
        self.vehicles = vehicles
        self.stops = stops
    }

    /// Runs that ran with this series ("ICE 4").
    public struct VehicleShare: Sendable, Hashable {
        public var name: String
        public var runs: Int

        public init(name: String, runs: Int) {
            self.name = name
            self.runs = runs
        }
    }

    /// One planned platform and the one the train really used, with the runs that did.
    public struct PlatformMove: Sendable, Hashable, Decodable {
        public var from: String
        public var to: String
        public var n: Int

        public init(from: String, to: String, n: Int) {
            self.from = from
            self.to = to
            self.n = n
        }
    }

    /// One stop of the train in the runs.
    public struct Stop: Sendable, Hashable, Decodable {
        /// Runs that had the stop in their schedule, and how many of them skipped it (or didn't run).
        public var runs: Int
        public var cancelled: Int
        /// Delays in minutes of the runs that served the stop; negative when early.
        public var arrival: [Int]
        public var departure: [Int]
        public var platforms: [PlatformMove]

        public init(runs: Int, cancelled: Int = 0, arrival: [Int] = [], departure: [Int] = [], platforms: [PlatformMove] = []) {
            self.runs = runs
            self.cancelled = cancelled
            self.arrival = arrival
            self.departure = departure
            self.platforms = platforms
        }
    }

    // MARK: - Reading

    /// The share of runs that were cancelled altogether.
    public var cancelledShare: Double? {
        runs >= Self.minimumRuns ? Double(cancelledRuns) / Double(runs) : nil
    }

    /// How often another vehicle than the planned one ran, and which.
    public struct UnplannedVehicles: Sendable, Hashable {
        /// The share of runs that differed from their day's schedule.
        public var share: Double
        /// The series that ran then, most common first.
        public var vehicles: [Option]

        public struct Option: Sendable, Hashable {
            public var name: String
            /// The share of the runs that differed.
            public var share: Double
        }
    }

    /// Nil without enough runs, or when the planned vehicle always ran.
    public var unplannedVehicles: UnplannedVehicles? {
        guard formationRuns >= Self.minimumRuns, unplannedRuns > 0 else { return nil }
        let named = vehicles.reduce(0) { $0 + $1.runs }
        guard named > 0 else { return nil }
        return UnplannedVehicles(share: Double(unplannedRuns) / Double(formationRuns),
                                 vehicles: vehicles.map { .init(name: $0.name, share: Double($0.runs) / Double(named)) })
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case category, number, days, runs, cancelled, formationRuns, unplannedRuns, unplannedFormations, stops
    }

    /// One kind of vehicle in bahn.de's Wagenreihung shape: the app names its series with the rules it
    /// uses for a live Wagenreihung.
    private struct Formation: Decodable {
        var n: Int
        var groups: [BahnDeClient.SequenceResponse.Group]?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decode(String.self, forKey: .category)
        number = try c.decode(String.self, forKey: .number)
        days = try c.decode(Int.self, forKey: .days)
        runs = try c.decode(Int.self, forKey: .runs)
        cancelledRuns = try c.decode(Int.self, forKey: .cancelled)
        stops = try c.decodeIfPresent([String: Stop].self, forKey: .stops) ?? [:]
        formationRuns = try c.decodeIfPresent(Int.self, forKey: .formationRuns) ?? 0
        unplannedRuns = try c.decodeIfPresent(Int.self, forKey: .unplannedRuns) ?? 0

        var runsBySeries: [String: Int] = [:]
        var order: [String] = []
        let wanted = Int(number)
        for formation in try c.decodeIfPresent([Formation].self, forKey: .unplannedFormations) ?? [] {
            let sequence = BahnDeClient.SequenceResponse(groups: formation.groups)
            let units = BahnDeClient.formation(from: sequence, category: category, number: wanted).units
            var names: [String] = []
            for name in units.compactMap({ TrainModel.name($0.model, unit: $0.number) }) where !names.contains(name) {
                names.append(name)
            }
            guard !names.isEmpty else { continue }
            let series = names.joined(separator: " + ")
            if runsBySeries[series] == nil { order.append(series) }
            runsBySeries[series, default: 0] += formation.n
        }
        vehicles = order.map { VehicleShare(name: $0, runs: runsBySeries[$0]!) }.sorted { $0.runs > $1.runs }
    }
}

// MARK: - Stops

extension TrainStatistics.Stop {
    /// How late the train was at a stop: its average and the share of runs on time.
    public struct DelaySummary: Sendable, Hashable {
        public var runs: Int
        /// Average delay in whole minutes.
        public var average: Int
        public var onTimeShare: Double
    }

    public func arrivalSummary() -> DelaySummary? { Self.summary(arrival) }
    public func departureSummary() -> DelaySummary? { Self.summary(departure) }

    static func summary(_ delays: [Int]) -> DelaySummary? {
        guard delays.count >= TrainStatistics.minimumRuns else { return nil }
        let average = Double(delays.reduce(0, +)) / Double(delays.count)
        let onTime = delays.filter { $0 <= TrainStatistics.onTimeMinutes }.count
        return DelaySummary(runs: delays.count, average: Int(average.rounded()), onTimeShare: Double(onTime) / Double(delays.count))
    }

    /// The share of runs that arrived at least `minutes` late, e.g. the time a transfer takes. Cancelled
    /// runs don't count: a cancellation is no delay. Nil without enough runs.
    public func arrivalLateShare(atLeast minutes: Int) -> Double? {
        guard arrival.count >= TrainStatistics.minimumRuns else { return nil }
        return Double(arrival.filter { $0 >= minutes }.count) / Double(arrival.count)
    }

    /// The share of runs that skipped the stop or didn't run at all.
    public var cancelledShare: Double? {
        runs >= TrainStatistics.minimumRuns ? Double(cancelled) / Double(runs) : nil
    }

    /// A platform the train used instead of the planned one, with its share of the runs planned there.
    public struct PlatformOption: Sendable, Hashable {
        public var platform: String
        public var share: Double
    }

    /// What happened to the runs planned for `planned`: how often the train used another platform, and
    /// which ones, most likely first. Nil without a platform or without enough runs for it.
    public struct PlatformOutlook: Sendable, Hashable {
        public var runs: Int
        public var changeShare: Double
        public var alternatives: [PlatformOption]
    }

    public func platformOutlook(planned: String?) -> PlatformOutlook? {
        guard let planned, !planned.isEmpty else { return nil }
        let moves = platforms.filter { $0.from == planned }
        let total = moves.reduce(0) { $0 + $1.n }
        guard total >= TrainStatistics.minimumRuns else { return nil }
        let changed = moves.filter { $0.to != planned }
        let alternatives = changed.sorted { $0.n != $1.n ? $0.n > $1.n : $0.to < $1.to }
            .map { PlatformOption(platform: $0.to, share: Double($0.n) / Double(total)) }
        return PlatformOutlook(runs: total, changeShare: Double(changed.reduce(0) { $0 + $1.n }) / Double(total),
                               alternatives: alternatives)
    }
}

// MARK: - Transfers

extension TrainStatistics.Stop {
    /// How a transfer fares when the incoming train arrives as it usually does.
    public struct TransferOutlook: Sendable, Hashable {
        public var runs: Int
        /// The planned time between the two trains.
        public var bufferMinutes: Int
        /// The share of runs that arrived at least `bufferMinutes` late.
        public var lateShare: Double
        public var averageDelay: Int

        /// Late often enough to be worth a warning.
        public var isRisky: Bool { lateShare >= 0.2 }
    }

    public func transferOutlook(bufferMinutes: Int) -> TransferOutlook? {
        guard bufferMinutes > 0, let late = arrivalLateShare(atLeast: bufferMinutes), let summary = arrivalSummary() else { return nil }
        return TransferOutlook(runs: summary.runs, bufferMinutes: bufferMinutes, lateShare: late, averageDelay: summary.average)
    }
}

/// A transfer with little time between the trains: what the incoming train usually does at that station.
public struct TightTransfer: Sendable, Hashable, Identifiable {
    /// The incoming leg's ID.
    public var id: String
    public var line: Line?
    public var station: Station
    public var bufferMinutes: Int
    /// When the incoming train arrives, which also names the day the figures are kept for.
    public var arrival: Date
}

extension Journey {
    /// The transfers with at most `upTo` planned minutes, which a delay of the incoming train can break.
    public func tightTransfers(upTo limit: Int = 10) -> [TightTransfer] {
        let legs = transitLegs
        return zip(legs, legs.dropFirst()).compactMap { leg, next in
            let buffer = Int((next.departure.planned.timeIntervalSince(leg.arrival.planned) / 60).rounded())
            guard buffer > 0, buffer <= limit, !leg.cancelled, let line = leg.line, line.product.hasTrainStatistics else { return nil }
            return TightTransfer(id: leg.id, line: line, station: leg.destination, bufferMinutes: buffer, arrival: leg.arrival.planned)
        }
    }
}

// MARK: - Asking the server

/// A train and the stops (EVA numbers) the app wants figures for.
public struct TrainStatisticsQuery: Sendable, Hashable {
    public var category: String
    public var number: String
    public var evas: [String]

    public init(category: String, number: String, evas: [String]) {
        self.category = category.uppercased()
        self.number = number
        self.evas = evas
    }

    /// The query for `line`'s train at the stops `evas`; nil for trains the server doesn't collect
    /// (S-Bahn, buses, trains without a number) or without any stop.
    public init?(line: Line?, evas: [String]) {
        // A regional train is known by its run number; its `number` is the line's ("RE 5" → 5).
        let regional = line?.product == .regional || line?.product == .regionalExpress
        guard let line, line.product.hasTrainStatistics,
              let number = regional ? line.tripNumber : (line.tripNumber ?? line.number), !number.isEmpty,
              case let category = String(line.name.prefix { $0.isLetter }), !category.isEmpty else { return nil }
        var unique: [String] = []
        for eva in evas where !unique.contains(eva) { unique.append(eva) }
        guard !unique.isEmpty else { return nil }
        self.init(category: category, number: number, evas: unique)
    }

    /// One train and day: the cache key.
    public func key(day: String) -> String { "\(category)|\(number)|\(day)" }
}

extension Product {
    /// Regional and long-distance trains are what `Cloudflare/stats` collects.
    var hasTrainStatistics: Bool {
        switch self {
        case .highSpeed, .longDistance, .nightTrain, .interregio, .regionalExpress, .regional: true
        default: false
        }
    }
}

extension Station {
    /// The EVA number as bahn.de's runs know it.
    var statisticsEVA: String? {
        if let eva = evaNumber, !eva.isEmpty, eva.allSatisfy(\.isNumber) { return eva }
        return id.allSatisfy(\.isNumber) && !id.isEmpty ? id : nil
    }
}

public struct TrainStatisticsClient: Sendable {
    /// The Worker takes at most this many trains and stops per train.
    static let maxTrains = 8
    static let maxStops = 12

    let http: HTTPClient
    let auth: WorkerAuth?
    let baseURL: URL

    public init(http: HTTPClient = HTTPClient(timeout: 15), auth: WorkerAuth? = nil, baseURL: URL = TrainSightings.baseURL) {
        self.http = http
        self.auth = auth
        self.baseURL = baseURL
    }

    private struct Request: Encodable {
        struct Train: Encodable { var category: String; var number: String; var evas: [String] }
        var trains: [Train]
    }

    private struct Response: Decodable {
        var trains: [TrainStatistics]
    }

    /// The figures for these trains (one request per `maxTrains`), in no particular order.
    public func statistics(for queries: [TrainStatisticsQuery]) async throws -> [TrainStatistics] {
        var answers: [TrainStatistics] = []
        for start in stride(from: 0, to: queries.count, by: Self.maxTrains) {
            let batch = queries[start..<min(start + Self.maxTrains, queries.count)]
            var request = URLRequest(url: baseURL.appending(path: "train-stats"), timeoutInterval: http.timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Request(trains: batch.map {
                .init(category: $0.category, number: $0.number, evas: Array($0.evas.prefix(Self.maxStops)))
            }))
            let data = try await http.sendRaw(request, auth: http.workerAuth(auth))
            do {
                answers += try JSONDecoder().decode(Response.self, from: data).trains
            } catch {
                throw TransitError.decoding(String(describing: error))
            }
        }
        return answers
    }
}

/// The figures of one train, with the stops asked for found by their station.
public struct TrainStatisticsLookup: Sendable, Hashable {
    public var statistics: TrainStatistics
    /// Station ID → EVA number of the stops asked for.
    var evas: [String: String]

    public func stop(at station: Station) -> TrainStatistics.Stop? {
        evas[station.id].flatMap { statistics.stops[$0] }
    }
}

// MARK: - Cache

/// Looks the figures up once per train and day and keeps them: a journey with a few trains costs one
/// request, and showing it again costs none. Off (nothing asked, nothing shown) while the user doesn't
/// share train data, see `TrainSightings`.
public actor TrainStatisticsStore {
    public static let shared = TrainStatisticsStore()
    /// After a failed lookup the Worker isn't asked again for a train this long.
    static let retryAfter: TimeInterval = 5 * 60

    public typealias Fetcher = @Sendable ([TrainStatisticsQuery]) async throws -> [TrainStatistics]
    /// Finds the EVA number of a station the feed gave none for (`BahnDeClient.evaNumber(for:)`).
    public typealias EVAResolver = @Sendable (Station) async -> String?

    private let fetcher: Fetcher
    private let now: @Sendable () -> Date
    private var isEnabled = false
    private var entries: [String: TrainStatistics] = [:]
    /// The stops asked for per train and day, answered or not.
    private var asked: [String: Set<String>] = [:]
    private var failures: [String: Date] = [:]
    /// Station ID → EVA number, for the stations that needed a lookup.
    private var resolved: [String: String] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }, fetcher: Fetcher? = nil) {
        self.now = now
        self.fetcher = fetcher ?? { queries in try await TrainStatisticsClient().statistics(for: queries) }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// "2026-10-14": the day figures are kept for, in Germany's time.
    public static func day(of date: Date) -> String { BahnDeClient.berlinDay(date) }

    /// The figures for `line`'s train on `date`'s day at `stations`. A station without an EVA number is
    /// looked up with `resolve`, once.
    public func lookup(line: Line?, at stations: [Station], on date: Date, resolve: EVAResolver? = nil) async -> TrainStatisticsLookup? {
        guard isEnabled, let line, line.product.hasTrainStatistics else { return nil }
        let evas = await evaNumbers(of: stations, resolve: resolve)
        guard let query = TrainStatisticsQuery(line: line, evas: Array(evas.values.sorted())) else { return nil }
        let day = Self.day(of: date)
        guard let statistics = await self.statistics(for: [query], day: day)[query.key(day: day)] else { return nil }
        return TrainStatisticsLookup(statistics: statistics, evas: evas)
    }

    /// What the incoming trains of `transfers` usually do at the transfer stations, by `TightTransfer.id`.
    public func outlooks(for transfers: [TightTransfer], resolve: EVAResolver? = nil) async -> [String: TrainStatistics.Stop.TransferOutlook] {
        guard isEnabled else { return [:] }
        var queries: [(transfer: TightTransfer, eva: String, query: TrainStatisticsQuery)] = []
        for transfer in transfers {
            guard let eva = await evaNumbers(of: [transfer.station], resolve: resolve)[transfer.station.id],
                  let query = TrainStatisticsQuery(line: transfer.line, evas: [eva]) else { continue }
            queries.append((transfer, eva, query))
        }
        var result: [String: TrainStatistics.Stop.TransferOutlook] = [:]
        for (day, group) in Dictionary(grouping: queries, by: { Self.day(of: $0.transfer.arrival) }) {
            let figures = await statistics(for: group.map(\.query), day: day)
            for (transfer, eva, query) in group {
                if let outlook = figures[query.key(day: day)]?.stops[eva]?.transferOutlook(bufferMinutes: transfer.bufferMinutes) {
                    result[transfer.id] = outlook
                }
            }
        }
        return result
    }

    private func evaNumbers(of stations: [Station], resolve: EVAResolver?) async -> [String: String] {
        var evas: [String: String] = [:]
        for station in stations {
            if let eva = station.statisticsEVA ?? resolved[station.id] {
                evas[station.id] = eva
            } else if let resolve, let eva = await resolve(station), !eva.isEmpty, eva.allSatisfy(\.isNumber) {
                resolved[station.id] = eva
                evas[station.id] = eva
            }
        }
        return evas
    }

    /// The figures for `query` on `day` ("2026-10-14") if they are known already, without asking.
    public func cached(_ query: TrainStatisticsQuery, day: String) -> TrainStatistics? {
        isEnabled ? entries[query.key(day: day)] : nil
    }

    /// The figures for these trains on `day`, asking the server only for what isn't known yet. Trains
    /// the server has nothing on are missing from the result.
    @discardableResult
    public func statistics(for queries: [TrainStatisticsQuery], day: String) async -> [String: TrainStatistics] {
        guard isEnabled else { return [:] }
        let current = now()
        var missing: [TrainStatisticsQuery] = []
        for query in queries {
            let key = query.key(day: day)
            let unknown = query.evas.filter { !(asked[key]?.contains($0) ?? false) }
            if unknown.isEmpty || (failures[key].map { current.timeIntervalSince($0) < Self.retryAfter } ?? false) { continue }
            missing.append(TrainStatisticsQuery(category: query.category, number: query.number, evas: unknown))
        }
        if !missing.isEmpty {
            do {
                let answers = try await fetcher(missing)
                for query in missing {
                    let key = query.key(day: day)
                    asked[key, default: []].formUnion(query.evas)
                    failures[key] = nil
                    guard let answer = answers.first(where: { $0.category == query.category && $0.number == query.number }) else { continue }
                    var merged = answer
                    merged.stops = (entries[key]?.stops ?? [:]).merging(answer.stops) { $1 }
                    entries[key] = merged
                }
            } catch {
                for query in missing { failures[query.key(day: day)] = current }
            }
        }
        var result: [String: TrainStatistics] = [:]
        for query in queries {
            if let entry = entries[query.key(day: day)] { result[query.key(day: day)] = entry }
        }
        return result
    }
}
