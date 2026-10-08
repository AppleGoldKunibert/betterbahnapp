import Foundation

/// A train as typed when picking one for a route (#225): "ICE 423", "423", "RE 3", "RE 3300" or
/// "RE 3 (3300)" the way DB writes a regional train with its run number.
public struct TrainNameQuery: Sendable, Hashable {
    /// The text without the run number in brackets, normalized ("re3" for "RE 3 (3300)").
    public var name: String
    /// Letters typed before the first number, lower-cased ("re"); nil when there are none.
    public var category: String?
    /// The number that names one run: the one in brackets, else the last number typed.
    public var number: String?
    /// Whether that number came in brackets – then it alone decides, "RE 3" in front only describes the line.
    public var isRunNumber: Bool

    public init(_ text: String) {
        var outside = text
        var bracketed: String?
        if let open = text.lastIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            let inside = text[text.index(after: open)..<close].filter(\.isNumber)
            if !inside.isEmpty {
                bracketed = String(inside)
                outside = String(text[..<open]) + String(text[text.index(after: close)...])
            }
        }
        name = Line.normalize(outside)
        let letters = name.prefix { $0.isLetter }
        category = letters.isEmpty ? nil : String(letters)
        let trailing = String(name.reversed().prefix(while: \.isNumber).reversed())
        number = bracketed ?? (trailing.isEmpty ? nil : trailing)
        isRunNumber = bracketed != nil
        if let number { self.number = Self.trimmingZeros(number) }
    }

    /// Nothing to look for.
    public var isEmpty: Bool { name.isEmpty && number == nil }

    /// The query as the train search reads it (`TrainNumberSearch`), when it has a number.
    public var numberQuery: TrainNumberQuery? {
        guard let number, let value = Int(number) else { return nil }
        return TrainNumberQuery(category: category?.uppercased(), number: value)
    }

    /// Whether `line` is the train meant: its name ("ICE 423", also a coupled train's or the other
    /// brand's), a bare number as its train or run number ("3300" for the RE 3 that runs as 3300), a
    /// category with a run number ("RE 3300"), or the run number in brackets ("RE3 (3346)").
    public func matches(_ line: Line) -> Bool {
        if !isRunNumber, !name.isEmpty, line.allNames.contains(where: { Line.normalize($0) == name }) { return true }
        guard let number, Self.numbers(of: line).contains(number) else { return false }
        return fitsCategory(line)
    }

    /// How well `line` fits while the name is still being typed: 2 for a full match, 1 when one of its
    /// names or numbers starts with what was typed ("ICE 5" → ICE 597), nil when it doesn't fit.
    public func score(_ line: Line) -> Int? {
        if matches(line) { return 2 }
        guard !isEmpty else { return nil }
        if isRunNumber, let number {
            return Self.numbers(of: line).contains { $0.hasPrefix(number) } && fitsCategory(line) ? 1 : nil
        }
        if !name.isEmpty, line.allNames.contains(where: { Line.normalize($0).hasPrefix(name) }) { return 1 }
        if let number, Self.numbers(of: line).contains(where: { $0.hasPrefix(number) }), fitsCategory(line) { return 1 }
        return nil
    }

    /// No category typed, or the line's name starts with it ("re" for "RE 3", "ice" for an ICE also called "RJ 177").
    private func fitsCategory(_ line: Line) -> Bool {
        guard let category else { return true }
        return line.allNames.contains { Line.normalize($0).hasPrefix(category) }
    }

    /// Every number the train goes by: its own, its run number and those in its other names, without leading zeros.
    static func numbers(of line: Line) -> Set<String> {
        let trailing = line.allNames.map { name in String(name.reversed().prefix(while: \.isNumber).reversed()) }
        return Set(([line.number, line.tripNumber].compactMap { $0 } + trailing).filter { !$0.isEmpty }.map(trimmingZeros))
    }

    static func trimmingZeros(_ number: String) -> String {
        let trimmed = String(number.drop { $0 == "0" })
        return trimmed.isEmpty ? number : trimmed
    }
}

/// A train that fits what was typed, with where it would be boarded on the route and – if it goes
/// there – where to get off for the destination.
public struct TrainCandidate: Sendable, Hashable, Identifiable {
    public var trip: Trip
    /// The stop on the route where it is boarded; nil when it calls at none of the route's stations
    /// (found by number elsewhere), then the boarding stop has to be picked by hand.
    public var boardingIndex: Int?
    /// The destination (or the next train's boarding stop) when the train calls there after boarding.
    public var exitIndex: Int?
    /// The name or number matches in full, not only its beginning.
    public var isExact: Bool

    public var id: String { trip.id + "|\(boardingIndex ?? -1)" }
    public var boarding: Stopover? { boardingIndex.map { trip.stopovers[$0] } }
    public var exit: Stopover? { exitIndex.map { trip.stopovers[$0] } }

    public init(trip: Trip, boardingIndex: Int?, exitIndex: Int?, isExact: Bool) {
        self.trip = trip
        self.boardingIndex = boardingIndex
        self.exitIndex = exitIndex
        self.isExact = isExact
    }
}

/// A run found by number for the train list, with where it meets the route once its stops are in.
public struct NumberedTrain: Sendable, Hashable, Identifiable {
    public var result: TrainSearchResult
    /// Nil until its stops are loaded (`TrainCandidateFinder.routeFit`).
    public var fit: RouteFit?

    public var id: String { result.id }

    public init(result: TrainSearchResult, fit: RouteFit? = nil) {
        self.result = result
        self.fit = fit
    }
}

/// Where a run found by number meets the route.
public struct RouteFit: Sendable, Hashable {
    /// The route station it is boarded at, nil when it calls at none of them.
    public var boarding: Station?
    /// When it leaves there, planned.
    public var departure: Date?
    /// It calls at the destination after boarding.
    public var reachesTarget: Bool
    /// It runs through one of the countries wanted (Settings → Zugschnellsuche).
    public var inCountries: Bool

    public init(boarding: Station?, departure: Date?, reachesTarget: Bool, inCountries: Bool) {
        self.boarding = boarding
        self.departure = departure
        self.reachesTarget = reachesTarget
        self.inCountries = inCountries
    }
}

/// Finds the trains that fit a typed name or number for a route (#225): first on the departure boards
/// of the route's stations (where you'd board, `routeCandidates`), and for a number the way the train
/// search does it: bahn.expert lists the runs with that number at once (`numberTrains`), each run's
/// stops then tell whether it calls on the route and at the destination (`routeFit`), and only the
/// picked one has its trip loaded (`candidate(for:)`). The ones going to the destination come first.
///
/// The boards are slow (a few seconds each), so they are loaded in parallel, can be loaded before the
/// first letter is typed (`prefetch`), and are shared by every search while the sheet is open.
public actor TrainCandidateFinder {
    public let provider: CombinedProvider
    let numberSearch: TrainNumberSearch?
    /// How far before the given time the boards start, and how many minutes they cover.
    let minutesBefore: Int
    let windowMinutes: Int
    /// Boards and runs loading or loaded, so each typed letter doesn't ask again. A request isn't
    /// cancelled when the search that started it is (typing on), and a failed one isn't kept.
    private var boards: [String: Task<[BoardEntry]?, Never>] = [:]
    private var trips: [String: Task<Trip?, Never>] = [:]

    public init(provider: CombinedProvider, minutesBefore: Int = 30, windowMinutes: Int = 360) {
        self.provider = provider
        self.numberSearch = TrainNumberSearch(provider: provider)
        self.minutesBefore = minutesBefore
        self.windowMinutes = windowMinutes
    }

    /// Starts loading the boards of `stations`, so the first search finds them ready.
    public func prefetch(stations: [Station], date: Date) async {
        await withTaskGroup(of: Void.self) { group in
            for station in Self.places(stations) {
                group.addTask { _ = await self.board(at: station, date: date) }
            }
        }
    }

    /// Up to `limit` trains matching `text` that leave one of `stations` (in order of preference)
    /// from about `date`, best fit for reaching `target` first.
    public func routeCandidates(for text: String, stations: [Station], target: Station, date: Date,
                                limit: Int = 8) async -> [TrainCandidate] {
        let query = TrainNameQuery(text)
        guard !query.isEmpty else { return [] }
        let places = Self.places(stations)
        let loaded = await withTaskGroup(of: (Int, [BoardEntry]).self) { group in
            for (rank, station) in places.enumerated() {
                group.addTask { (rank, await self.board(at: station, date: date)) }
            }
            var boards: [(Int, [BoardEntry])] = []
            for await board in group { boards.append(board) }
            return boards.sorted { $0.0 < $1.0 }
        }
        var entries: [(entry: BoardEntry, score: Int, stationRank: Int)] = []
        var seen = Set<String>()
        for (rank, board) in loaded {
            for entry in board {
                guard entry.line.product.isTrain, !entry.cancelled, entry.access != .exitOnly,
                      let score = query.score(entry.line), seen.insert(entry.tripId).inserted else { continue }
                entries.append((entry, score, rank))
            }
        }
        // Full matches, then the stations the user would be at first, then the time closest to the given one.
        entries.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.stationRank != b.stationRank { return a.stationRank < b.stationRank }
            return abs(a.entry.time.planned.timeIntervalSince(date)) < abs(b.entry.time.planned.timeIntervalSince(date))
        }
        let picked = Array(entries.prefix(Self.maxTripLoads))
        let results = await withTaskGroup(of: TrainCandidate?.self) { group in
            var iterator = picked.makeIterator()
            var running = 0
            var results: [TrainCandidate] = []
            func addNext() -> Bool {
                guard let item = iterator.next() else { return false }
                group.addTask { await self.loadCandidate(item.entry, exact: item.score == 2, target: target) }
                return true
            }
            // At most 4 parallel requests, like the other planners; the next starts as soon as one is done.
            while running < 4, addNext() { running += 1 }
            while let candidate = await group.next() {
                if let candidate { results.append(candidate) }
                _ = addNext()
            }
            return results
        }
        return Array(Self.ranked(results, target: target, date: date).prefix(limit))
    }

    // MARK: - By number, like the train search

    /// The runs with the typed number on `date`'s day, as the train search lists them (one request to
    /// bahn.expert, the kinds of trains from Settings → Zugschnellsuche, fastest kind first); nil
    /// without a number or when bahn.expert doesn't answer, so the boards' trains are all there is.
    /// Countries aren't checked here: that needs a run's stops, which `routeFit` loads anyway.
    public func numberTrains(for text: String, date: Date, filter: TrainSearchFilter) async -> [TrainSearchResult]? {
        guard let numberSearch, let query = TrainNameQuery(text).numberQuery else { return nil }
        return try? await numberSearch.trains(query, on: date, filter: TrainSearchFilter(kinds: filter.kinds, countries: []))
    }

    /// Whether `result` is in one of `countries` from its ends alone: true when it starts or ends there,
    /// false when it can't pass through one in between, nil when only its stops can tell.
    public static func countryStatus(_ result: TrainSearchResult, countries: Set<String>) -> Bool? {
        if countries.isEmpty || TrainNumberSearch.endsIn(countries, result) { return true }
        return TrainNumberSearch.mayPassThrough(result) ? nil : false
    }

    /// Where the run meets the route, from its stops (one small request to bahn.expert).
    public func routeFit(of result: TrainSearchResult, stations: [Station], target: Station,
                         countries: Set<String>) async -> RouteFit? {
        guard let numberSearch, let stops = try? await numberSearch.bahnExpert.stops(ofJourney: result.journeyId) else { return nil }
        return Self.fit(stops: stops, stations: Self.places(stations), target: target, countries: countries)
    }

    /// The first of `stations` (in their order) the run leaves from, whether it calls at `target` after
    /// that, and whether it runs through one of `countries`.
    static func fit(stops: [TrainSearchStop], stations: [Station], target: Station, countries: Set<String>) -> RouteFit {
        func matches(_ stop: TrainSearchStop, _ station: Station) -> Bool {
            if let eva = station.evaNumber, eva == stop.evaNumber { return true }
            return Station.normalize(Station.displayName(for: stop.name)) == Station.normalize(station.displayName)
        }
        var boarding: (index: Int, station: Station)?
        for station in stations {
            if let index = stops.firstIndex(where: { $0.plannedDeparture != nil && matches($0, station) }) {
                boarding = (index, station)
                break
            }
        }
        let reaches = boarding.map { b in stops[(b.index + 1)...].contains { matches($0, target) } } ?? false
        let inCountries = countries.isEmpty || stops.contains { $0.country.map(countries.contains) == true }
        return RouteFit(boarding: boarding?.station, departure: boarding.flatMap { stops[$0.index].plannedDeparture },
                        reachesTarget: reaches, inCountries: inCountries)
    }

    /// Going to the target first, then boardable on the route, then leaving closest to `date`; else
    /// the train search's own order. Runs whose stops aren't known yet keep their place behind those.
    public static func ranked(_ trains: [NumberedTrain], date: Date) -> [NumberedTrain] {
        trains.enumerated().sorted { a, b in
            func key(_ t: NumberedTrain, _ offset: Int) -> (Int, Int, Double, Int) {
                let fit = t.fit
                return (fit?.reachesTarget == true ? 0 : 1, fit?.boarding != nil ? 0 : 1,
                        fit?.departure.map { abs($0.timeIntervalSince(date)) } ?? .greatestFiniteMagnitude, offset)
            }
            return key(a.element, a.offset) < key(b.element, b.offset)
        }.map(\.element)
    }

    /// The boards' trains that aren't runs of `number` – those come from the train search already.
    /// Only the run's own number counts: an RE 3 running as 3300 is no run of "3".
    public static func boardExtras(_ route: [TrainCandidate], besides number: Int) -> [TrainCandidate] {
        let wanted = String(number)
        return route.filter { candidate in
            guard let run = candidate.trip.line?.dispatchNumber else { return true }
            return TrainNameQuery.trimmingZeros(run) != wanted
        }
    }

    /// The picked run's trip, to show its stops: from the boarding station's board when the route
    /// meets it (one small board), else wherever the train search finds it (`TrainNumberSearch.run`).
    public func candidate(for train: NumberedTrain, target: Station) async throws -> TrainCandidate {
        guard let numberSearch else { throw TransitError.notFound("\(train.result.name) im Fahrplan") }
        if let station = train.fit?.boarding, let departure = train.fit?.departure,
           let entries = try? await provider.departuresForTrainLookup(at: station, date: departure.addingTimeInterval(-2 * 60),
                                                                     duration: 5, products: Self.trainProducts),
           let entry = TrainNumberSearch.entry(for: train.result, departing: departure, in: entries),
           let trip = await trip(id: entry.tripId, source: entry.source) {
            return Self.candidate(trip, boardingAt: station, near: departure, target: target, exact: true)
        }
        let (_, trip) = try await numberSearch.run(of: train.result)
        return Self.candidate(trip, boardingAt: train.fit?.boarding, near: train.fit?.departure, target: target, exact: true)
    }

    /// Best first: full matches, boardable on the route, going to the target (earliest arrival), else
    /// getting closest to it, then leaving closest to `date`.
    static func ranked(_ candidates: [TrainCandidate], target: Station, date: Date) -> [TrainCandidate] {
        func key(_ c: TrainCandidate) -> (Int, Int, Int, Double, Double) {
            let reaches = c.exit?.arrival?.best.timeIntervalSince1970
            let closest = c.boardingIndex.flatMap { closestDistance(c.trip, after: $0, to: target) } ?? .greatestFiniteMagnitude
            let departure = c.boarding?.departure?.planned ?? c.trip.stopovers.first?.departure?.planned ?? date
            return (c.isExact ? 0 : 1, c.boardingIndex == nil ? 1 : 0, reaches == nil ? 1 : 0,
                    reaches ?? closest, abs(departure.timeIntervalSince(date)))
        }
        return candidates.sorted { key($0) < key($1) }
    }

    /// How close the train gets to `target` after boarding, in metres; nil without coordinates.
    static func closestDistance(_ trip: Trip, after boardingIndex: Int, to target: Station) -> Double? {
        guard let goal = target.coordinate else { return nil }
        return trip.stopovers[(boardingIndex + 1)...].compactMap { $0.station.coordinate?.distance(to: goal) }.min()
    }

    /// Where `trip` is boarded at `station` and left at `target`, when it calls there afterwards.
    static func candidate(_ trip: Trip, boardingAt station: Station?, near time: Date?, target: Station, exact: Bool) -> TrainCandidate {
        let boarding = station.flatMap { station in
            trip.stopovers.indices.filter { trip.stopovers[$0].station.isSamePlace(as: station) && trip.stopovers[$0].departure != nil }
                .min { a, b in
                    guard let time else { return a < b }
                    return abs((trip.stopovers[a].departure?.planned ?? .distantFuture).timeIntervalSince(time))
                        < abs((trip.stopovers[b].departure?.planned ?? .distantFuture).timeIntervalSince(time))
                }
        }
        let exit = boarding.flatMap { index in
            trip.stopovers[(index + 1)...].firstIndex { $0.station.isSamePlace(as: target) && $0.arrival != nil && $0.access.allowsAlighting }
        }
        return TrainCandidate(trip: trip, boardingIndex: boarding, exitIndex: exit, isExact: exact)
    }

    /// The first `maxStations` of `stations`, each place once.
    static func places(_ stations: [Station]) -> [Station] {
        var places: [Station] = []
        for station in stations where !places.contains(where: { $0.isSamePlace(as: station) }) { places.append(station) }
        return Array(places.prefix(maxStations))
    }

    // MARK: - Loading

    private func loadCandidate(_ entry: BoardEntry, exact: Bool, target: Station) async -> TrainCandidate? {
        guard let trip = await trip(id: entry.tripId, source: entry.source) else { return nil }
        return Self.candidate(trip, boardingAt: entry.station, near: entry.time.planned, target: target, exact: exact)
    }

    /// The station's trains (only trains: a smaller board) for the window around `date`.
    private func board(at station: Station, date: Date) async -> [BoardEntry] {
        let start = date.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        let key = station.id + "|\(Int(start.timeIntervalSince1970 / 300))"
        let task: Task<[BoardEntry]?, Never>
        if let loading = boards[key] {
            task = loading
        } else {
            let provider = provider, duration = windowMinutes
            // The lookup board: without loading every long-distance train's run for its destination, which
            // at a hub took longer than the board's deadline and came back empty.
            task = Task { try? await provider.departuresForTrainLookup(at: station, date: start, duration: duration,
                                                                       products: Self.trainProducts) }
            boards[key] = task
        }
        guard let entries = await task.value else {
            boards[key] = nil
            return []
        }
        return entries
    }

    private func trip(id: String, source: DataSource) async -> Trip? {
        let task: Task<Trip?, Never>
        if let loading = trips[id] {
            task = loading
        } else {
            let provider = provider
            task = Task { try? await provider.trip(id: id, source: source) }
            trips[id] = task
        }
        guard let trip = await task.value else {
            trips[id] = nil
            return nil
        }
        return trip
    }

    static let trainProducts = Set(Product.allCases.filter(\.isTrain))
    /// How many of the route's stations have their board asked.
    static let maxStations = 4
    /// How many matching departures get their run loaded to see where they go.
    static let maxTripLoads = 10
    /// How many runs found by number are looked up (each costs a station search and a board).
    static let maxNumberRuns = 3
}
