import Foundation

// The delays a train really had on one day, from the statistics server (`POST /train-stats` with a `day`),
// to show on journeys whose live data is long gone.

extension TrainStatistics {
    /// How far back the server has a day's run: every train for the last 30 days, long-distance trains for about
    /// a year (the server keeps them longer). A little short of that, so a request doesn't fall on the edge.
    public static let regionalRunDays = 29
    public static let longDistanceRunDays = 360
    /// A leg this recent still has its live data, or the server hasn't taken the day in yet.
    public static let runMinimumAge: TimeInterval = 3600

    /// One run of one train on one day, as the server's `run` says it. Stops are in route order, with the EVA numbers
    /// of the main stations (lower levels are folded into them).
    public struct Run: Sendable, Hashable, Codable {
        public struct Stop: Sendable, Hashable, Codable {
            public var eva: String
            /// Minutes late (negative when early); nil when unknown or when the stop was cancelled.
            public var arrivalDelay: Int?
            public var departureDelay: Int?
            public var platform: String?
            public var changedPlatform: String?
            public var cancelled: Bool
            /// A stop the train made in addition to its schedule.
            public var additional: Bool

            public init(eva: String, arrivalDelay: Int? = nil, departureDelay: Int? = nil, platform: String? = nil,
                        changedPlatform: String? = nil, cancelled: Bool = false, additional: Bool = false) {
                self.eva = eva
                self.arrivalDelay = arrivalDelay
                self.departureDelay = departureDelay
                self.platform = platform
                self.changedPlatform = changedPlatform
                self.cancelled = cancelled
                self.additional = additional
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                eva = try c.decode(String.self, forKey: .eva)
                arrivalDelay = try c.decodeIfPresent(Int.self, forKey: .arrivalDelay)
                departureDelay = try c.decodeIfPresent(Int.self, forKey: .departureDelay)
                platform = try c.decodeIfPresent(String.self, forKey: .platform)
                changedPlatform = try c.decodeIfPresent(String.self, forKey: .changedPlatform)
                cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
                additional = try c.decodeIfPresent(Bool.self, forKey: .additional) ?? false
            }
        }

        /// "2026-10-30", the operating day in Germany.
        public var day: String
        public var category: String
        /// The train did not run at all.
        public var cancelled: Bool
        public var stops: [Stop]

        public init(day: String, category: String, cancelled: Bool = false, stops: [Stop]) {
            self.day = day
            self.category = category
            self.cancelled = cancelled
            self.stops = stops
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(String.self, forKey: .day)
            category = try c.decode(String.self, forKey: .category)
            cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
            stops = try c.decodeIfPresent([Stop].self, forKey: .stops) ?? []
        }
    }
}

// MARK: - Asking

extension TrainStatisticsClient {
    /// A train on one day.
    public struct RunQuery: Sendable, Hashable {
        public var train: TrainStatisticsQuery
        /// "2026-10-30".
        public var day: String

        public init(train: TrainStatisticsQuery, day: String) {
            self.train = train
            self.day = day
        }

        /// The start of the day in Germany; the distant past for a day that doesn't read as one.
        public var dayStart: Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return .distantPast }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? .distantPast
        }
    }

    private struct RunRequest: Encodable {
        struct Train: Encodable { var category: String; var number: String; var evas: [String]; var day: String }
        var trains: [Train]
    }

    private struct RunResponse: Decodable {
        struct Entry: Decodable {
            var run: TrainStatistics.Run?
            /// Whether the answer has the key `run` at all (null: no such run). A server that doesn't know the
            /// `day` yet (an older Worker) leaves it out and says nothing about the day.
            var answered: Bool

            private enum CodingKeys: String, CodingKey { case run }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                answered = c.contains(.run)
                run = try c.decodeIfPresent(TrainStatistics.Run.self, forKey: .run)
            }
        }
        var trains: [Entry]
    }

    public enum RunError: Error {
        /// The server answered without `run`: it doesn't know how to answer for a day (yet). Nothing is learned from
        /// that, so the caller must not remember "no run" but ask again later.
        case dayNotSupported
    }

    /// The runs of these trains on their days, one request per `maxTrains`; a train the server has no run
    /// for (too old, never seen) is left out. Throws when a request fails or the server doesn't answer for days
    /// (`RunError.dayNotSupported`), so the caller asks again later.
    public func runs(for queries: [RunQuery]) async throws -> [RunQuery: TrainStatistics.Run] {
        var answers: [RunQuery: TrainStatistics.Run] = [:]
        for start in stride(from: 0, to: queries.count, by: Self.maxTrains) {
            let batch = Array(queries[start..<min(start + Self.maxTrains, queries.count)])
            var request = URLRequest(url: baseURL.appending(path: "train-stats"), timeoutInterval: http.timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(RunRequest(trains: batch.map {
                .init(category: $0.train.category, number: $0.train.number, evas: Array($0.train.evas.prefix(Self.maxStops)), day: $0.day)
            }))
            let data = try await http.sendRaw(request, auth: http.workerAuth(auth))
            let entries: [RunResponse.Entry]
            do {
                entries = try JSONDecoder().decode(RunResponse.self, from: data).trains
            } catch {
                throw TransitError.decoding(String(describing: error))
            }
            guard entries.count == batch.count, entries.allSatisfy(\.answered) else { throw RunError.dayNotSupported }
            // The server answers in the order asked.
            for (query, entry) in zip(batch, entries) {
                if let run = entry.run { answers[query] = run }
            }
        }
        return answers
    }
}

// MARK: - Applying

extension Leg {
    /// What to ask the server to learn this leg's real delays: nil for a walk, a train the server doesn't
    /// collect, a leg that still has live data or lies beyond what the server keeps, or one that already
    /// has real times.
    public func statisticsRunQuery(now: Date = .now) -> TrainStatisticsClient.RunQuery? {
        guard !isWalking, !hasActualTimes,
              arrival.planned.addingTimeInterval(TrainStatistics.runMinimumAge) < now,
              let line, line.product.hasTrainStatistics else { return nil }
        let longDistance = line.product != .regional && line.product != .regionalExpress
        let limit = TimeInterval(longDistance ? TrainStatistics.longDistanceRunDays : TrainStatistics.regionalRunDays) * 86400
        guard now.timeIntervalSince(departure.planned) < limit else { return nil }
        let evas = [origin, destination].compactMap(\.runEVA)
        guard let train = TrainStatisticsQuery(line: line, evas: evas) else { return nil }
        return .init(train: train, day: BahnDeClient.berlinDay(departure.planned))
    }

    /// Whether any time of the leg is a real one.
    public var hasActualTimes: Bool {
        departure.actual != nil || arrival.actual != nil
            || stopovers.contains { $0.arrival?.actual != nil || $0.departure?.actual != nil }
    }

    /// The leg with the delays and cancelled stops of `run`: each stop of the leg (and its start and end) gets
    /// its planned time plus the run's delay. Only a leg without any real time is touched, so live data always
    /// wins, and only one that is over (`TrainStatistics.runMinimumAge`).
    public func applying(_ run: TrainStatistics.Run, now: Date = .now) -> Leg {
        guard !isWalking, !hasActualTimes, arrival.planned.addingTimeInterval(TrainStatistics.runMinimumAge) < now else { return self }
        var stops: [String: TrainStatistics.Run.Stop] = [:]
        for stop in run.stops where stops[stop.eva] == nil { stops[stop.eva] = stop }
        func stop(at station: Station) -> TrainStatistics.Run.Stop? {
            station.runEVA.flatMap { stops[TrainStatistics.mainStationEVA($0)] }
        }
        func shifted(_ time: TimeInfo, by delay: Int?) -> TimeInfo {
            guard let delay else { return time }
            return TimeInfo(planned: time.planned, actual: time.planned.addingTimeInterval(TimeInterval(delay) * 60))
        }

        var leg = self
        if run.cancelled {
            leg.cancelled = true
            for index in leg.stopovers.indices { leg.stopovers[index].cancelled = true }
            return leg
        }
        leg.departure = shifted(leg.departure, by: stop(at: origin)?.departureDelay)
        leg.arrival = shifted(leg.arrival, by: stop(at: destination)?.arrivalDelay)
        for index in leg.stopovers.indices {
            guard let found = stop(at: leg.stopovers[index].station) else { continue }
            if found.cancelled {
                leg.stopovers[index].cancelled = true
                continue
            }
            leg.stopovers[index].arrival = leg.stopovers[index].arrival.map { shifted($0, by: found.arrivalDelay) }
            leg.stopovers[index].departure = leg.stopovers[index].departure.map { shifted($0, by: found.departureDelay) }
        }
        return leg
    }
}

extension Journey {
    /// The journey with the real delays of `runs` (by `Leg.id`) put on the legs that have none.
    public func applying(_ runs: [String: TrainStatistics.Run], now: Date = .now) -> Journey {
        guard !runs.isEmpty else { return self }
        var journey = self
        for index in journey.legs.indices {
            if let run = runs[journey.legs[index].id] { journey.legs[index] = journey.legs[index].applying(run, now: now) }
        }
        return journey
    }
}

extension TrainStatistics {
    /// The EVA number a station is kept under in the statistics: the lower levels of the big stations ("Berlin
    /// Hbf (tief)") are folded into the main station (as `Cloudflare/stats` does).
    static func mainStationEVA(_ eva: String) -> String {
        for (main, lowers) in TimetablesClient.lowerLevels where lowers.contains(eva) { return main }
        return eva
    }
}

extension Station {
    /// The EVA number to ask the statistics with: the one the feed gave, else the offline list's by the station's
    /// name (as the live statistics do before asking bahn.de), so a journey from a feed without EVA numbers
    /// (Transitous) is asked for too.
    var runEVA: String? {
        statisticsEVA ?? StationNames.mainEvaNumber(for: self)
    }
}
