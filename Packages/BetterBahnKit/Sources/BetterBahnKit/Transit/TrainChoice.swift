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

/// Finds the trains that fit a typed name or number for a route (#225): first on the departure boards
/// of the route's stations (where you'd board), then – for a number – with the train search, which
/// knows every run by number. The ones going to the destination come first.
///
/// The boards are slow (a few seconds each), so they are loaded in parallel, can be loaded before the
/// first letter is typed (`prefetch`), and are shared by every search while the sheet is open. The
/// train search is slower still, so its runs come separately (`numberCandidates`) and never hold up
/// the trains already found on the boards (`routeCandidates`).
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

    /// Both kinds of trains together (see `routeCandidates` and `numberCandidates`), best fit first.
    public func candidates(for text: String, stations: [Station], target: Station, date: Date,
                           limit: Int = 8) async -> [TrainCandidate] {
        async let byNumber = numberCandidates(for: text, stations: stations, target: target, date: date)
        let route = await routeCandidates(for: text, stations: stations, target: target, date: date, limit: limit)
        return Self.merged(route, await byNumber, target: target, date: date, limit: limit)
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

    /// Runs found by number (the train search), for trains the route's boards don't have – e.g. one
    /// boarded at a station the route only passes later. Boarded at the first route station it calls at.
    /// Slow (a station search and a board per run), so asked alongside `routeCandidates`, not before.
    public func numberCandidates(for text: String, stations: [Station], target: Station,
                                 date: Date) async -> [TrainCandidate] {
        guard let numberSearch, let numberQuery = TrainNameQuery(text).numberQuery,
              let found = try? await numberSearch.trains(numberQuery, on: date) else { return [] }
        let places = Self.places(stations)
        return await withTaskGroup(of: TrainCandidate?.self) { group in
            for result in found.prefix(Self.maxNumberRuns) {
                group.addTask {
                    guard let (_, trip) = try? await numberSearch.run(of: result) else { return nil }
                    let station = places.first { station in trip.stopovers.contains { $0.station.isSamePlace(as: station) } }
                    return Self.candidate(trip, boardingAt: station, near: date, target: target, exact: true)
                }
            }
            var results: [TrainCandidate] = []
            for await candidate in group { if let candidate { results.append(candidate) } }
            return results
        }
    }

    /// The trains from the boards with those found by number added (each run once), best fit first.
    public static func merged(_ route: [TrainCandidate], _ byNumber: [TrainCandidate], target: Station, date: Date,
                              limit: Int = 8) -> [TrainCandidate] {
        let known = Set(route.map(\.trip.id))
        return Array(ranked(route + byNumber.filter { !known.contains($0.trip.id) }, target: target, date: date).prefix(limit))
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
