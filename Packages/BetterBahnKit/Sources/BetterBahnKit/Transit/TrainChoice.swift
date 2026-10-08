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
public actor TrainCandidateFinder {
    public let provider: CombinedProvider
    let numberSearch: TrainNumberSearch?
    /// How far before the given time the boards start, and how many minutes they cover.
    let minutesBefore: Int
    let windowMinutes: Int
    /// Boards and runs already loaded, so each typed letter doesn't ask again.
    private var boards: [String: [BoardEntry]] = [:]
    private var trips: [String: Trip] = [:]

    public init(provider: CombinedProvider, minutesBefore: Int = 30, windowMinutes: Int = 360) {
        self.provider = provider
        self.numberSearch = TrainNumberSearch(provider: provider)
        self.minutesBefore = minutesBefore
        self.windowMinutes = windowMinutes
    }

    /// Up to `limit` trains matching `text` that can be boarded at one of `stations` (in order of
    /// preference) from about `date`, best fit for reaching `target` first.
    public func candidates(for text: String, stations: [Station], target: Station, date: Date,
                           limit: Int = 8) async -> [TrainCandidate] {
        let query = TrainNameQuery(text)
        guard !query.isEmpty else { return [] }
        var places: [Station] = []
        for station in stations where !places.contains(where: { $0.isSamePlace(as: station) }) { places.append(station) }
        places = Array(places.prefix(Self.maxStations))

        async let found = numberSearchCandidates(query, stations: places, target: target, date: date)
        var entries: [(entry: BoardEntry, score: Int, stationRank: Int)] = []
        var seen = Set<String>()
        for (rank, station) in places.enumerated() {
            for entry in await board(at: station, date: date) {
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
        var results: [TrainCandidate] = []
        for chunk in Array(entries.prefix(Self.maxTripLoads)).chunked(into: 4) {
            await withTaskGroup(of: TrainCandidate?.self) { group in
                for item in chunk {
                    group.addTask { await self.loadCandidate(item.entry, exact: item.score == 2, target: target) }
                }
                for await candidate in group { if let candidate { results.append(candidate) } }
            }
        }
        let fromBoards = Set(results.map(\.trip.id))
        results += await found.filter { !fromBoards.contains($0.trip.id) }
        return Array(Self.ranked(results, target: target, date: date).prefix(limit))
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

    // MARK: - Loading

    private func loadCandidate(_ entry: BoardEntry, exact: Bool, target: Station) async -> TrainCandidate? {
        guard let trip = await trip(id: entry.tripId, source: entry.source) else { return nil }
        return Self.candidate(trip, boardingAt: entry.station, near: entry.time.planned, target: target, exact: exact)
    }

    /// Runs found by number (the train search), for trains the route's boards don't have – e.g. one
    /// boarded at a station the route only passes later. Boarded at the first route station it calls at.
    private func numberSearchCandidates(_ query: TrainNameQuery, stations: [Station], target: Station,
                                        date: Date) async -> [TrainCandidate] {
        guard let numberSearch, let numberQuery = query.numberQuery,
              let found = try? await numberSearch.trains(numberQuery, on: date) else { return [] }
        var results: [TrainCandidate] = []
        for result in found.prefix(Self.maxNumberRuns) {
            guard let (_, trip) = try? await numberSearch.run(of: result) else { continue }
            let station = stations.first { station in trip.stopovers.contains { $0.station.isSamePlace(as: station) } }
            results.append(Self.candidate(trip, boardingAt: station, near: date, target: target, exact: true))
        }
        return results
    }

    private func board(at station: Station, date: Date) async -> [BoardEntry] {
        let start = date.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        let key = station.id + "|\(Int(start.timeIntervalSince1970 / 300))"
        if let cached = boards[key] { return cached }
        let entries = (try? await provider.departures(at: station, date: start, duration: windowMinutes)) ?? []
        boards[key] = entries
        return entries
    }

    private func trip(id: String, source: DataSource) async -> Trip? {
        if let cached = trips[id] { return cached }
        guard let trip = try? await provider.trip(id: id, source: source) else { return nil }
        trips[id] = trip
        return trip
    }

    /// How many of the route's stations have their board asked.
    static let maxStations = 4
    /// How many matching departures get their run loaded to see where they go.
    static let maxTripLoads = 12
    /// How many runs found by number are looked up (each costs a station search and a board).
    static let maxNumberRuns = 3
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
