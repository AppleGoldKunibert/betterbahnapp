import Foundation

/// A train number as typed into the train search (#183): "ICE 123", "ice123", "123", "S 37856".
public struct TrainNumberQuery: Sendable, Hashable {
    /// The category if one was typed, upper-cased ("ICE"); nil for a bare number.
    public var category: String?
    public var number: Int

    public init(category: String?, number: Int) {
        self.category = category
        self.number = number
    }

    /// Reads "ICE 123", "ICE123", "ice  123" and "123"; nil without a number at the end.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = String(trimmed.reversed().prefix(while: \.isNumber).reversed())
        guard !digits.isEmpty, digits.count <= 6, let number = Int(digits), number > 0 else { return nil }
        let category = trimmed.dropLast(digits.count).filter { $0.isLetter }.uppercased()
        self.init(category: category.isEmpty ? nil : category, number: number)
    }
}

/// One train run found by its number, on one day.
public struct TrainSearchResult: Sendable, Hashable, Identifiable {
    /// bahn.expert's journey ID ("20261007-88a26d04-…").
    public var journeyId: String
    /// As the operator spells it: "ICE", "S", "neg"; "-" or empty when it names none.
    public var category: String
    public var number: Int
    /// The operator's line, e.g. "S8" or "RB65"; nil for long-distance trains.
    public var line: String?
    public var product: Product
    /// Where the run starts and ends, as shown ("Frankfurt (Main) Hbf").
    public var origin: String
    public var destination: String
    public var originEVA: String?
    public var destinationEVA: String?
    /// Countries of the first and last stop (ISO codes, "DE"), when known.
    public var originCountry: String?
    public var destinationCountry: String?

    public var id: String { journeyId }

    /// Which group of the train search's filter it falls into.
    public var kind: TrainSearchKind {
        if category.uppercased() == "FLX" { return .flx }
        switch product {
        case .highSpeed: return .ice
        case .longDistance: return .icEc
        case .regionalExpress: return .re
        case .regional: return .rb
        case .suburban: return .sBahn
        default: return .other
        }
    }

    /// "ICE 123", "S 37856"; a train without a category goes by its line ("RS5 37856").
    public var name: String {
        let prefix = Self.hasCategory(category) ? category : (line ?? "")
        return prefix.isEmpty ? "\(number)" : "\(prefix) \(number)"
    }

    /// The line where it says more than the name: "S8" for "S 37856", but nothing for "ICE 123".
    public var lineName: String? {
        guard let line, !line.isEmpty, Self.hasCategory(category),
              Line.normalize(line) != Line.normalize(category) else { return nil }
        return line
    }

    static func hasCategory(_ category: String) -> Bool {
        category.contains(where: \.isLetter)
    }

    public init(journeyId: String, category: String, number: Int, line: String?, product: Product,
                origin: String, destination: String, originEVA: String?, destinationEVA: String?,
                originCountry: String? = nil, destinationCountry: String? = nil) {
        self.journeyId = journeyId
        self.category = category
        self.number = number
        self.line = line
        self.product = product
        self.origin = origin
        self.destination = destination
        self.originEVA = originEVA
        self.destinationEVA = destinationEVA
        self.originCountry = originCountry ?? TrainSearchCountry.code(eva: originEVA)
        self.destinationCountry = destinationCountry ?? TrainSearchCountry.code(eva: destinationEVA)
    }
}

/// The groups of trains the train search shows or hides (Settings → Zugschnellsuche).
public enum TrainSearchKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// ICE and other high-speed trains (ECE, TGV, Railjet, …).
    case ice
    /// IC, EC and other long-distance trains (IR, NJ, EN, D, …).
    case icEc
    case flx
    case re
    case rb
    case sBahn
    /// Buses, trams, ferries and anything else bahn.expert lists under the number.
    case other

    public var displayName: String {
        switch self {
        case .ice: "ICE"
        case .icEc: "IC/EC"
        case .flx: "FLX"
        case .re: "RE"
        case .rb: "RB"
        case .sBahn: "S-Bahn"
        case .other: "Sonstiges"
        }
    }

    /// Every train, nothing else.
    public static let defaults: Set<TrainSearchKind> = Set(allCases).subtracting([.other])
}

/// A country a train can run through, for the train search's filter.
public struct TrainSearchCountry: Sendable, Hashable, Identifiable {
    /// ISO 3166 code, "DE".
    public var code: String
    public var name: String
    public var id: String { code }

    public var flag: String {
        String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
    }

    /// Germany and the countries its trains run to, plus a few beyond.
    public static let all: [TrainSearchCountry] = [
        ("DE", "Deutschland"), ("AT", "Österreich"), ("CH", "Schweiz"), ("NL", "Niederlande"), ("BE", "Belgien"),
        ("LU", "Luxemburg"), ("FR", "Frankreich"), ("DK", "Dänemark"), ("PL", "Polen"), ("CZ", "Tschechien"),
        ("IT", "Italien"), ("SE", "Schweden"), ("NO", "Norwegen"), ("HU", "Ungarn"), ("SK", "Slowakei"),
        ("SI", "Slowenien"), ("HR", "Kroatien"), ("ES", "Spanien"), ("GB", "Großbritannien"),
    ].map { TrainSearchCountry(code: $0.0, name: $0.1) }

    public static let defaults: Set<String> = ["DE"]

    /// UIC country codes, the first two digits of a station's 7-digit EVA number.
    static let uicCodes: [String: String] = [
        "80": "DE", "81": "AT", "85": "CH", "84": "NL", "88": "BE", "82": "LU", "87": "FR", "86": "DK",
        "51": "PL", "54": "CZ", "83": "IT", "74": "SE", "76": "NO", "55": "HU", "56": "SK", "79": "SI",
        "78": "HR", "71": "ES", "70": "GB",
    ]

    /// A stop's country: its IFOPT's ("de:06412:10", "ch:1:sloid:174") if given, else from a 7-digit EVA number.
    static func code(eva: String?, ifopt: String? = nil) -> String? {
        if let prefix = ifopt?.split(separator: ":").first, prefix.count == 2, prefix.allSatisfy(\.isLetter) {
            return prefix.uppercased()
        }
        guard let eva, eva.count == 7, eva.allSatisfy(\.isNumber) else { return nil }
        return uicCodes[String(eva.prefix(2))]
    }
}

/// What the train search shows: these kinds of trains, running through one of these countries.
public struct TrainSearchFilter: Sendable, Hashable {
    public var kinds: Set<TrainSearchKind>
    /// ISO codes; empty means anywhere.
    public var countries: Set<String>

    public init(kinds: Set<TrainSearchKind> = TrainSearchKind.defaults, countries: Set<String> = TrainSearchCountry.defaults) {
        self.kinds = kinds
        self.countries = countries
    }
}

/// One stop of a run found by number: enough to find the train on that station's board.
public struct TrainSearchStop: Sendable, Hashable {
    public var evaNumber: String
    public var name: String
    public var plannedDeparture: Date?

    public init(evaNumber: String, name: String, plannedDeparture: Date?) {
        self.evaNumber = evaNumber
        self.name = name
        self.plannedDeparture = plannedDeparture
    }

    var country: String? { TrainSearchCountry.code(eva: evaNumber) }
}

/// Finds a train by its number (#183), without knowing where it runs: bahn.expert lists the runs
/// with that number on a day and their stops; the chosen one is then looked up on a stop's board
/// like any other train, so its trip comes from the usual provider (live times, saving, check-in,
/// Wagenreihung and live map all work as from a departure board).
public struct TrainNumberSearch: Sendable {
    public let provider: CombinedProvider
    let bahnExpert: BahnExpertClient

    /// nil without bahn.expert, which is the only source that finds a train by number alone.
    public init?(provider: CombinedProvider) {
        guard let bahnExpert = provider.bahnExpert else { return nil }
        self.provider = provider
        self.bahnExpert = bahnExpert
    }

    /// Runs with this number starting on `date`'s day (Berlin time) that `filter` lets through, best match first.
    public func trains(_ query: TrainNumberQuery, on date: Date,
                       filter: TrainSearchFilter = TrainSearchFilter()) async throws -> [TrainSearchResult] {
        let found = try await bahnExpert.findTrains(number: query.number, category: query.category,
                                                    day: BahnDeClient.berlinDay(date))
        let ranked = Self.ranked(found, for: query, kinds: filter.kinds)
        guard !filter.countries.isEmpty else { return ranked }
        // Only the first and last stop are known so far; a train that may pass through a wanted
        // country in between (Salzburg–Innsbruck via Rosenheim) has its stops looked up.
        let unsure = ranked.filter { !Self.endsIn(filter.countries, $0) && Self.mayPassThrough($0) }
            .prefix(Self.maxPassThroughChecks)
        let passing = await withTaskGroup(of: String?.self) { group in
            var iterator = unsure.makeIterator()
            var running = 0
            var ids: Set<String> = []
            func addNext() -> Bool {
                guard let result = iterator.next() else { return false }
                group.addTask {
                    let stops = (try? await bahnExpert.stops(ofJourney: result.journeyId)) ?? []
                    return stops.contains { $0.country.map(filter.countries.contains) == true } ? result.journeyId : nil
                }
                return true
            }
            while running < 4, addNext() { running += 1 }
            while let id = await group.next() {
                if let id { ids.insert(id) }
                _ = addNext()
            }
            return ids
        }
        return ranked.filter { Self.endsIn(filter.countries, $0) || passing.contains($0.journeyId) }
    }

    /// The chosen run as a board entry (to open `TripView` with) and its trip.
    /// - Throws: `TransitError.notFound` when no stop's board has the train.
    public func run(of result: TrainSearchResult) async throws -> (entry: BoardEntry, trip: Trip) {
        let stops = try await bahnExpert.stops(ofJourney: result.journeyId)
        for stop in Self.lookupStops(stops) {
            guard let planned = stop.plannedDeparture, let station = await station(for: stop),
                  let entries = try? await provider.departures(at: station, date: planned.addingTimeInterval(-2 * 60), duration: 5),
                  let entry = Self.entry(for: result, departing: planned, in: entries),
                  let trip = try? await provider.trip(id: entry.tripId, source: entry.source)
            else { continue }
            return (entry, trip)
        }
        throw TransitError.notFound("\(result.name) im Fahrplan")
    }

    /// bahn.de's station search knows the EVA numbers bahn.expert gives; the provider's is the fallback.
    private func station(for stop: TrainSearchStop) async -> Station? {
        if let bahnDe = provider.bahnDe, let found = try? await bahnDe.searchStations(stop.name),
           let match = found.first(where: { $0.evaNumber == stop.evaNumber }) {
            return match
        }
        let target = Station.normalize(Station.displayName(for: stop.name))
        let found = (try? await provider.searchStations(stop.name)) ?? []
        return found.first { $0.evaNumber == stop.evaNumber || Station.normalize($0.displayName) == target }
    }

    // MARK: - Helpers

    /// Categories typed for long-distance trains (DB's and its neighbours').
    static let longDistanceCategories: Set<String> = BahnDeClient.longDistanceCategories.union(["IR", "TGV", "NJ", "EN", "FLX", "EST", "D"])

    /// How many stops are tried before giving up: each costs a station search and a board.
    static let maxLookupStops = 3

    /// How many runs at most get their stops looked up for the country filter, one request each.
    static let maxPassThroughChecks = 12

    /// Starts or ends in one of `countries`.
    static func endsIn(_ countries: Set<String>, _ result: TrainSearchResult) -> Bool {
        [result.originCountry, result.destinationCountry].contains { $0.map(countries.contains) == true }
    }

    /// Whether a run may cross another country between its ends: long-distance trains, and any train
    /// whose ends lie in different (or unknown) countries. A regional train within one country abroad
    /// isn't looked up.
    static func mayPassThrough(_ result: TrainSearchResult) -> Bool {
        if [.ice, .icEc, .flx].contains(result.kind) { return true }
        guard let origin = result.originCountry, let destination = result.destinationCountry else { return true }
        return origin != destination
    }

    /// Where to look the train up: stops it departs from, German ones first (Transitous has DB's
    /// complete timetable; abroad it may only know the other operator's name for the train).
    static func lookupStops(_ stops: [TrainSearchStop]) -> [TrainSearchStop] {
        let departing = stops.filter { $0.plannedDeparture != nil }
        let german = departing.filter { $0.evaNumber.hasPrefix("80") }
        return Array((german + departing.filter { !$0.evaNumber.hasPrefix("80") }).prefix(maxLookupStops))
    }

    /// The board entry leaving at the run's planned time under its number or name; else under its line
    /// ("S2"), as Transitous doesn't know every S-Bahn's run number.
    static func entry(for result: TrainSearchResult, departing planned: Date, in entries: [BoardEntry]) -> BoardEntry? {
        let number = String(result.number)
        let name = Line.normalize(result.name)
        let atTime = entries.filter { abs($0.time.planned.timeIntervalSince(planned)) < 60 }
        if let match = atTime.first(where: { entry in
            let line = entry.line
            return line.dispatchNumber == number || line.number == number
                || line.allNames.contains { Line.normalize($0) == name }
        }) { return match }
        guard let lineName = result.line.map(Line.normalize), lineName.contains(where: \.isLetter) else { return nil }
        return atTime.first { Line.normalize($0.line.name) == lineName }
    }

    /// The kinds of trains wanted (bahn.expert also lists buses, trams and ferries with the number), the
    /// typed category alone when it matches any, faster trains first.
    static func ranked(_ results: [TrainSearchResult], for query: TrainNumberQuery,
                       kinds: Set<TrainSearchKind> = TrainSearchKind.defaults) -> [TrainSearchResult] {
        let trains = results.filter { $0.number == query.number && kinds.contains($0.kind) }
        var picked = trains
        if let category = query.category {
            let exact = trains.filter { Line.normalize($0.category) == Line.normalize(category)
                || $0.line.map { Line.normalize($0) == Line.normalize(category) } == true }
            // Feeds disagree on RE vs. RB and ICE vs. ECE, so without an exact match the same kind of train counts.
            let longDistance: Set<Product> = [.highSpeed, .longDistance]
            let typedLongDistance = longDistanceCategories.contains(Line.normalize(category).uppercased())
            picked = exact.isEmpty ? trains.filter { longDistance.contains($0.product) == typedLongDistance } : exact
        }
        let order: [Product] = [.highSpeed, .longDistance, .regionalExpress, .regional, .suburban]
        return picked.enumerated().sorted { a, b in
            let ra = order.firstIndex(of: a.element.product) ?? order.count
            let rb = order.firstIndex(of: b.element.product) ?? order.count
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}

extension BahnExpertClient {
    struct FoundRun: Decodable {
        struct Train: Decodable {
            var category: String?
            var journeyNumber: Int?
            var line: String?
            var transportType: String?
        }
        struct Stop: Decodable {
            struct Place: Decodable { var evaNumber: String?; var name: String?; var ifopt: String? }
            var stopPlace: Place
        }
        var journeyId: String
        var train: Train?
        var firstStop: Stop?
        var lastStop: Stop?
    }

    struct RunDetails: Decodable {
        struct Stop: Decodable {
            struct Place: Decodable { var evaNumber: String; var name: String }
            struct Event: Decodable { var scheduledTime: Date }
            var stopPlace: Place
            var departure: Event?
        }
        var stops: [Stop]
    }

    /// Every run with this number starting on `day` (`yyyy-MM-dd`), including buses and trams.
    /// bahn.expert takes the category only as a hint, so the caller filters.
    public func findTrains(number: Int, category: String?, day: String) async throws -> [TrainSearchResult] {
        guard Self.isValidDay(day) else { throw TransitError.invalidInput("Datum ungültig.") }
        var input: [String: Any] = ["journeyNumber": number, "initialDepartureDate": "\(day)T12:00:00.000Z", "withOEV": true]
        if let category { input["category"] = category }
        let found: [FoundRun]
        do {
            found = try await call("journey/find", input: ["json": input, "meta": [["date", "initialDepartureDate"]]])
        } catch TransitError.notFound {
            return []
        }
        return found.compactMap(Self.result)
    }

    /// A run's stops with their planned departures.
    public func stops(ofJourney journeyId: String) async throws -> [TrainSearchStop] {
        let details: RunDetails = try await call("journey/detailsByJourneyId", input: ["json": journeyId])
        return details.stops.map {
            TrainSearchStop(evaNumber: $0.stopPlace.evaNumber, name: $0.stopPlace.name,
                            plannedDeparture: $0.departure?.scheduledTime)
        }
    }

    static func result(_ run: FoundRun) -> TrainSearchResult? {
        guard let train = run.train, let number = train.journeyNumber else { return nil }
        let category = train.category ?? ""
        return TrainSearchResult(
            journeyId: run.journeyId, category: category, number: number, line: train.line,
            product: product(transportType: train.transportType, category: category),
            origin: Station.displayName(for: run.firstStop?.stopPlace.name ?? ""),
            destination: Station.displayName(for: run.lastStop?.stopPlace.name ?? ""),
            originEVA: run.firstStop?.stopPlace.evaNumber, destinationEVA: run.lastStop?.stopPlace.evaNumber,
            originCountry: run.firstStop.flatMap { TrainSearchCountry.code(eva: $0.stopPlace.evaNumber, ifopt: $0.stopPlace.ifopt) },
            destinationCountry: run.lastStop.flatMap { TrainSearchCountry.code(eva: $0.stopPlace.evaNumber, ifopt: $0.stopPlace.ifopt) })
    }

    /// bahn.expert's transport type; replacement buses come as regional trains of category "Bus".
    static func product(transportType: String?, category: String) -> Product {
        let category = category.uppercased()
        if category.hasPrefix("BUS") { return .bus }
        switch transportType {
        case "HIGH_SPEED_TRAIN": return .highSpeed
        case "INTERCITY_TRAIN", "INTER_REGIONAL_TRAIN": return .longDistance
        case "REGIONAL_TRAIN": return ["RE", "IRE", "REX"].contains(category) ? .regionalExpress : .regional
        case "CITY_TRAIN": return .suburban
        case "SUBWAY": return .subway
        case "TRAM": return .tram
        case "BUS", "SHUTTLE": return .bus
        case "FERRY": return .ferry
        default: return .other
        }
    }
}
