import Foundation

/// A coach type from bahn.de's seat picker (`gsd/api/wagentypen/<id>`, the id as the seat picker names a coach,
/// "I5812-412.(12-TLG.)-1"): the classes and pictograms of DB's seat plan of that coach. A type is the same for every
/// train of its series, so the app keeps the ones it has seen for good (`CoachTypeStore`).
public struct CoachType: Sendable, Hashable, Codable {
    /// One per part of the coach: "KLASSE_1", "KLASSE_2".
    public var classes: [String]
    /// The plan's pictograms: "SPEISEWAGEN", "ROLLSTUHL", "FAMILIENBEREICH", "RUHE", "FAHRRAD" …
    public var symbols: [String]

    public init(classes: [String], symbols: [String]) {
        self.classes = classes
        self.symbols = symbols
    }

    public var firstClass: Bool { classes.contains("KLASSE_1") }
    public var secondClass: Bool { classes.contains("KLASSE_2") }

    /// A coach with a restaurant or bistro next to its seats.
    public var kind: CoachSequence.Coach.Kind { symbols.contains("SPEISEWAGEN") ? .halfDiningCar : .passenger }

    public var amenities: [CoachSequence.Coach.Amenity] {
        CoachSequence.Coach.Amenity.allCases.filter { amenity in
            switch amenity {
            case .bikeSpace: symbols.contains("FAHRRAD")
            case .wheelchairSpace: symbols.contains("ROLLSTUHL")
            case .severelyDisabledSeats: symbols.contains("BEHINDERT")
            case .quietZone: symbols.contains("RUHE")
            case .familyZone: symbols.contains("FAMILIENBEREICH")
            case .infantCabin: symbols.contains("KLEINKINDABTEIL")
            case .wheelchairToilet, .bahnComfortSeats, .info: false
            }
        }
    }

    /// From bahn.de's answer; nil when it names no class.
    static func parse(_ data: Data) -> CoachType? {
        struct Response: Decodable {
            struct Part: Decodable { var klasse: String?; var elemente: [Element]? }
            struct Element: Decodable { var type: String?; var subtype: String? }
            var wagenteile: [Part]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let parts = response.wagenteile ?? []
        let classes = parts.compactMap(\.klasse)
        guard !classes.isEmpty else { return nil }
        var symbols: [String] = []
        for element in parts.flatMap({ $0.elemente ?? [] }) where element.type == "SYMBOL" {
            if let symbol = element.subtype, !symbols.contains(symbol) { symbols.append(symbol) }
        }
        return CoachType(classes: classes, symbols: symbols)
    }

    /// Whether `id` can be asked for: our server takes only such ids.
    static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.()\-]{0,63}/) != nil
    }

    /// The ICE series in a coach type's id: "412" from "I5812-412.(12-TLG.)-1", "403" from "I403F-403.RD-21";
    /// nil for anything else (an IC's or ICE L's coach).
    static func series(ofCoachType id: String) -> String? {
        let parts = id.split(separator: "-")
        guard parts.count >= 3 else { return nil }
        let series = String(parts[1].prefix { $0.isNumber })
        return VagonwebComposition.iceBaureihen.contains(series) ? series : nil
    }
}

/// The coach types seen so far, kept on the device for good: a type never changes, and each one is a request to
/// bahn.de through our server.
actor CoachTypeStore {
    /// The app's, in its caches folder.
    static let shared = CoachTypeStore(file: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "BetterBahn/bahnde-coach-types.json"))

    private let file: URL?
    /// Read from `file` on first use.
    private var types: [String: CoachType]?
    private var inFlight: [String: Task<CoachType?, Error>] = [:]

    init(file: URL?) {
        self.file = file
    }

    /// The type `id`, kept or asked for with `fetch`; a failed request is asked again next time.
    func type(_ id: String, fetch: @escaping @Sendable () async throws -> CoachType?) async throws -> CoachType? {
        if let type = load()[id] { return type }
        if let task = inFlight[id] { return try await task.value }
        let task = Task { try await fetch() }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        guard let type = try await task.value else { return nil }
        store(type, for: id)
        return type
    }

    private func store(_ type: CoachType, for id: String) {
        var kept = load()
        kept[id] = type
        types = kept
        guard let file, let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func load() -> [String: CoachType] {
        if let types { return types }
        let stored = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: CoachType].self, from: $0) } ?? [:]
        types = stored
        return stored
    }
}

// MARK: - Plan from the seat picker

extension CoachSequence {
    /// The planned Wagenreihung from bahn.de's seat picker (`SeatAvailability.parts`): the coaches with seats to
    /// reserve of each part of the train, by number, with class and amenities from their `types`. Without platform
    /// positions and direction; `ordered(like:)` takes those from vagonweb's plan. Nil without coaches.
    public static func seatPickerPlan(_ seats: SeatAvailability, types: [String: CoachType], trainName: String) -> CoachSequence? {
        var groups: [Group] = []
        var coaches: [Coach] = []
        for part in seats.parts where !part.isEmpty {
            let series = part.lazy.compactMap { $0.type.flatMap(CoachType.series(ofCoachType:)) }.first
            let family = series.flatMap {
                TrainTypeLookup.Group(seriesName: nil, baureihe: $0, unitNumber: nil, origin: nil, destination: nil, coachCount: part.count).family
            }
            groups.append(Group(trainName: trainName, destination: nil,
                                unit: family.map { TrainFormation.Unit(model: $0, number: nil) },
                                isRequestedTrain: true,
                                seatMapSheet: series.flatMap { seatMapSheet(series: $0, coachNumbers: part.map(\.number)) }))
            for listed in part {
                let type = listed.type.flatMap { types[$0] }
                coaches.append(Coach(
                    id: coaches.count, number: listed.number, kind: type?.kind ?? .passenger,
                    firstClass: type?.firstClass ?? false, secondClass: type?.secondClass ?? false, closed: false,
                    amenities: type?.amenities ?? [], bikeSpaces: nil, start: nil, end: nil, sector: nil,
                    group: groups.count - 1))
            }
        }
        guard !coaches.isEmpty else { return nil }
        return CoachSequence(
            platform: nil, platformLength: nil, sectors: [], groups: groups, coaches: coaches,
            travelsTowardsPlatformEnd: nil, differsFromSchedule: false,
            formation: TrainFormation(units: groups.compactMap(\.unit)), source: .seatPicker)
    }

    /// The seat-map sheet (`SeatMap.sheet`) of a trainset of the seat picker's `series`: every BR 403 runs redesigned,
    /// and the seat picker doesn't tell the two ICE T apart.
    static func seatMapSheet(series: String, coachNumbers: [String]) -> String? {
        let subtype: String? = switch series {
        case "403", "406": "403.R"
        case "411", "415": nil
        default: series
        }
        return SeatMap.sheet(subtype: subtype, coachNumbers: coachNumbers)
    }

    /// The seat picker's plan in the order of vagonweb's `plan` (turned round where the train changes direction on
    /// the way), with its direction and reversals, and the vehicles the seat picker doesn't list because they have no
    /// seats to reserve (locomotives, power cars, dining cars) where vagonweb has them. Coaches only the seat picker
    /// has stay at the end of their part. Unchanged when the two don't number the coaches alike.
    public func ordered(like plan: CoachSequence) -> CoachSequence {
        let mine = coaches.compactMap(\.number)
        let planned = plan.coaches.compactMap(\.number)
        guard mine.count == coaches.count, Set(mine).count == mine.count, Set(planned).count == planned.count else { return self }
        let shared = Set(mine).intersection(planned)
        guard shared.count * 2 >= mine.count else { return self }

        let byNumber = Dictionary(uniqueKeysWithValues: coaches.map { ($0.number!, $0) })
        var ordered: [Coach] = []
        // Vehicles of the plan only, waiting for the part they belong to (the next coach of the seat picker's).
        var waiting: [Coach] = []
        for vehicle in plan.coaches {
            if let number = vehicle.number, let coach = byNumber[number] {
                ordered += waiting.map { var vehicle = $0; vehicle.group = coach.group; return vehicle }
                waiting = []
                ordered.append(coach)
            } else if [.locomotive, .powerCar, .diningCar].contains(vehicle.kind) {
                var vehicle = vehicle
                if let last = ordered.last {
                    vehicle.group = last.group
                    ordered.append(vehicle)
                } else {
                    waiting.append(vehicle)
                }
            }
        }
        ordered += waiting.map { var vehicle = $0; vehicle.group = coaches.first?.group ?? 0; return vehicle }
        for coach in coaches where !shared.contains(coach.number!) {
            let index = ordered.lastIndex { $0.group == coach.group && $0.number != nil }.map { $0 + 1 } ?? ordered.endIndex
            ordered.insert(coach, at: index)
        }

        var sequence = self
        sequence.coaches = ordered.enumerated().map { index, coach in
            var coach = coach
            coach.id = index
            return coach
        }
        sequence.travelsTowardsPlatformEnd = plan.travelsTowardsPlatformEnd
        sequence.reversals = plan.reversals
        return sequence
    }
}

extension BahnDeClient {
    /// The seat picker's ride for the Wagenreihung at `request`'s stop: from there to the next stop (planned times),
    /// the class as given. Nil without the next stop, and for trains bahn.de sells no seats on.
    public static func seatRequest(for request: FormationRequest, travelClass: TravelClass) -> SeatRequest? {
        guard longDistanceCategories.contains(request.category.uppercased()), let next = request.nextStop,
              let arrival = request.nextArrival, arrival > request.plannedDeparture else { return nil }
        return SeatRequest(category: request.category, number: request.number, origin: request.station,
                           plannedDeparture: request.plannedDeparture, destination: next, plannedArrival: arrival,
                           travelClass: travelClass)
    }

    /// The planned Wagenreihung from the seat picker for `request`'s ride (`CoachSequence.seatPickerPlan`), each coach
    /// type asked for once on this device. With nothing left in the class asked for, the other class's answer, which
    /// lists the same coaches. Nil when bahn.de has no seat picker for the ride.
    public func seatPickerSequence(_ request: SeatRequest) async throws -> CoachSequence? {
        var seats = try await seatAvailability(request)
        if seats?.parts.isEmpty ?? true {
            var other = request
            other.travelClass = request.travelClass == .first ? .second : .first
            seats = try await seatAvailability(other)
        }
        guard let seats, !seats.parts.isEmpty else { return nil }
        let ids = Set(seats.parts.flatMap { $0.compactMap(\.type) }).filter(CoachType.isValidID)
        var types: [String: CoachType] = [:]
        for id in ids.sorted() {
            // A coach without its type still shows, just without class and amenities.
            if let type = try? await coachType(id) { types[id] = type }
        }
        return CoachSequence.seatPickerPlan(seats, types: types, trainName: "\(request.category.uppercased()) \(request.number)")
    }

    /// The coach type `id` (`CoachType`), from the device or asked once through our server.
    func coachType(_ id: String) async throws -> CoachType? {
        guard CoachType.isValidID(id) else { return nil }
        let url = Self.baseURL.appending(path: "gsd/api/wagentypen/\(id)")
        let fetch: @Sendable () async throws -> CoachType? = { [self] in
            CoachType.parse(try await getData(url))
        }
        guard usesSharedCaches else { return try await fetch() }
        return try await CoachTypeStore.shared.type(id, fetch: fetch)
    }
}
