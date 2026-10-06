import Foundation

/// A train's coach sequence ("Wagenreihung") at one stop: every coach with its number, class,
/// amenities and position along the platform, plus the platform's sectors.
public struct CoachSequence: Sendable, Hashable {
    public struct Sector: Sendable, Hashable {
        public var name: String
        /// Meters from the platform's start.
        public var start: Double
        public var end: Double
    }

    /// One coupled part of the train, e.g. a single ICE trainset. Split trains list the halves that
    /// run on as another train too.
    public struct Group: Sendable, Hashable {
        /// "ICE 940"
        public var trainName: String?
        public var destination: String?
        /// Triebzug number and Taufname, as in `TrainFormation.Unit`.
        public var unit: TrainFormation.Unit?
        /// Whether this part runs as the train that was asked for.
        public var isRequestedTrain: Bool
    }

    public struct Coach: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case passenger, diningCar, halfDiningCar, sleeper, couchette, locomotive, powerCar, other
        }

        public enum Amenity: String, Sendable, Hashable, CaseIterable {
            case bikeSpace = "BIKE_SPACE"
            case wheelchairSpace = "WHEELCHAIR_SPACE"
            case wheelchairToilet = "TOILET_WHEELCHAIR"
            case severelyDisabledSeats = "SEATS_SEVERELY_DISABLED"
            case quietZone = "ZONE_QUIET"
            case familyZone = "ZONE_FAMILY"
            case infantCabin = "CABIN_INFANT"
            case bahnComfortSeats = "SEATS_BAHN_COMFORT"
            case info = "INFO"
        }

        /// Position in the sequence (as bahn.de lists it, i.e. from the front of the train).
        public var id: Int
        /// Coach number passengers look for ("Wagen 21"); nil for locomotives and power cars.
        public var number: String?
        public var kind: Kind
        public var firstClass: Bool
        public var secondClass: Bool
        /// A coach that is locked for passengers.
        public var closed: Bool
        public var amenities: [Amenity]
        /// Number of bike spaces, if given.
        public var bikeSpaces: Int?
        /// Meters from the platform's start; nil when bahn.de gave no position.
        public var start: Double?
        public var end: Double?
        public var sector: String?
        /// Index into `CoachSequence.groups`.
        public var group: Int
        /// vagonweb.cz's side view of the coach; nil for bahn.de's coaches until `withDrawings(from:)`.
        public var drawing: Drawing? = nil

        /// A coach drawn by vagonweb.cz, as in Řazení vlaků: front of the train to the left.
        public struct Drawing: Sendable, Hashable {
            /// vagonweb's drawing as its plan has it (the train leaving its first station).
            public var url: URL
            /// The coach stands the other way round than in `url`'s drawing (the train changed direction).
            public var turned = false

            public init(url: URL, turned: Bool = false) {
                self.url = url
                self.turned = turned
            }

            /// vagonweb has every drawing for both directions, told apart by the name's end: "408-5-b.gif"
            /// and "408-5-a.gif". Nil when the name doesn't follow that pattern.
            public var otherWayURL: URL? {
                let name = url.lastPathComponent
                guard let match = name.firstMatch(of: #/-([ab])(\.[A-Za-z]+)$/#) else { return nil }
                let other = name[..<match.range.lowerBound] + (match.1 == "a" ? "-b" : "-a") + match.2
                return url.deletingLastPathComponent().appending(path: String(other))
            }

            /// What to load for the way the coach stands: the drawing for that direction first, else the
            /// plan's drawing mirrored.
            public var candidates: [(url: URL, mirrored: Bool)] {
                guard turned else { return [(url, false)] }
                return (otherWayURL.map { [($0, false)] } ?? []) + [(url, true)]
            }
        }

        /// Passengers can't board locomotives and power cars.
        public var isPassengerCoach: Bool { kind != .locomotive && kind != .powerCar }
    }

    public var platform: String?
    /// Platform length in meters; nil when bahn.de has no platform data.
    public var platformLength: Double?
    public var sectors: [Sector]
    public var groups: [Group]
    /// Front of the train first.
    public var coaches: [Coach]
    /// Whether the train leaves towards the platform's end (the last sector); nil when unknown. For
    /// vagonweb's plan (no platform) false means the first coach leads, nil that the direction is unknown.
    public var travelsTowardsPlatformEnd: Bool?
    /// bahn.de's own `sequenceStatus` flag. It is set for nearly every train (also when coaches and
    /// classes match the plan), so the app compares with vagonweb's plan itself (`deviations(fromPlan:)`).
    public var differsFromSchedule: Bool
    /// Series, Tz and Taufname of the requested train's trainsets.
    public var formation: TrainFormation

    public enum Source: Sendable, Hashable {
        /// bahn.de's coach sequence at a stop.
        case bahnDe
        /// vagonweb.cz's scheduled composition: the plan, without platform positions, sectors or Tz.
        case vagonweb(validFrom: Date?, validUntil: Date?)
    }

    public var source: Source = .bahnDe
    /// vagonweb's plan only: the stations up to this stop where the train changes direction (it is
    /// shown turned round after an odd number of them).
    public var reversals: [String] = []

    /// A group with nothing but locomotives. bahn.de lists a locomotive as its own group with the
    /// station where it is changed as destination, which is no part of the train passengers ride on.
    public func isLocomotiveOnly(group index: Int) -> Bool {
        let vehicles = coaches.filter { $0.group == index }
        return !vehicles.isEmpty && vehicles.allSatisfy { $0.kind == .locomotive }
    }

    /// The groups passengers ride in: all but those of locomotives alone.
    public var travellingGroups: [Group] {
        let travelling = groups.indices.filter { !isLocomotiveOnly(group: $0) }
        return travelling.isEmpty ? groups : travelling.map { groups[$0] }
    }

    /// Groups that run as another train with another destination than the requested one.
    public var hasOtherTrains: Bool { travellingGroups.contains { !$0.isRequestedTrain } }
    /// Several trains run in this consist, each under its own number (coupled, or split later on).
    public var hasSeveralTrains: Bool { Set(travellingGroups.compactMap(\.trainName)).count > 1 }
    /// Its parts go on to different places, so it matters which coach you board.
    public var partsGoToDifferentPlaces: Bool { Set(travellingGroups.compactMap(\.destination)).count > 1 }
}

// MARK: - Compared with the plan

extension CoachSequence {
    /// What differs from the planned Wagenreihung (vagonweb's), as short German notes: missing or
    /// extra coaches ("Wagen 31–39 fehlen") and coaches in another class. The order is left out on
    /// purpose: the same train standing the other way round (first class at the back after a change
    /// of direction) is not a different Wagenreihung, and the platform diagram already shows where
    /// each coach stops. Empty when nothing differs or there is no plan to compare with.
    public func deviations(fromPlan plan: CoachSequence) -> [String] {
        let planned = plan.coaches.filter(\.isPassengerCoach)
        let actual = coaches.filter(\.isPassengerCoach)
        guard !planned.isEmpty, !actual.isEmpty else { return [] }

        let plannedNumbers = planned.compactMap(\.number)
        let actualNumbers = Set(actual.compactMap(\.number))
        // Compare coach by coach when both number their coaches the same way.
        if plannedNumbers.count == planned.count, actualNumbers.count == actual.compactMap(\.number).count,
           actual.allSatisfy({ $0.number != nil }), !actualNumbers.isDisjoint(with: plannedNumbers) {
            var notes: [String] = []
            let missing = plannedNumbers.filter { !actualNumbers.contains($0) }
            if !missing.isEmpty {
                notes.append("Wagen \(Self.numberList(missing)) \(missing.count == 1 ? "fehlt" : "fehlen")")
            }
            // Coaches of trains coupled to this one aren't in its plan.
            if !hasSeveralTrains {
                let extra = actual.filter { coach in
                    groups.indices.contains(coach.group) && groups[coach.group].isRequestedTrain && !plannedNumbers.contains(coach.number!)
                }.compactMap(\.number)
                if !extra.isEmpty { notes.append("Zusätzlich Wagen \(Self.numberList(extra))") }
            }
            let plannedByNumber = Dictionary(planned.map { ($0.number!, $0) }, uniquingKeysWith: { first, _ in first })
            var nowFirst: [String] = []
            var nowSecond: [String] = []
            for coach in actual where coach.kind == .passenger {
                guard let plannedCoach = plannedByNumber[coach.number!], plannedCoach.kind == .passenger,
                      plannedCoach.firstClass != coach.firstClass else { continue }
                if coach.firstClass { nowFirst.append(coach.number!) } else { nowSecond.append(coach.number!) }
            }
            if !nowFirst.isEmpty { notes.append("Wagen \(Self.numberList(nowFirst)): 1. statt 2. Klasse") }
            if !nowSecond.isEmpty { notes.append("Wagen \(Self.numberList(nowSecond)): 2. statt 1. Klasse") }
            return notes
        }

        // Otherwise only the number of coaches and of first-class ones.
        var notes: [String] = []
        if actual.count != planned.count {
            notes.append("\(actual.count) statt \(planned.count) Wagen")
        }
        let actualFirst = actual.count { $0.firstClass }
        let plannedFirst = planned.count { $0.firstClass }
        if actualFirst != plannedFirst {
            notes.append("\(actualFirst) statt \(plannedFirst) Wagen mit 1. Klasse")
        }
        return notes
    }

    /// "21", "21, 23", "31–39": coach numbers in order, runs of three or more joined.
    static func numberList(_ numbers: [String]) -> String {
        let ints = numbers.compactMap { Int($0) }
        guard ints.count == numbers.count else { return numbers.joined(separator: ", ") }
        var parts: [String] = []
        var runStart: Int?
        var previous: Int?
        func close() {
            guard let start = runStart, let end = previous else { return }
            parts += end - start >= 2 ? ["\(start)–\(end)"] : (start...end).map(String.init)
        }
        for number in Set(ints).sorted() {
            if let last = previous, number == last + 1 {
                previous = number
            } else {
                close()
                runStart = number
                previous = number
            }
        }
        close()
        return parts.joined(separator: ", ")
    }

    /// The plan as the train runs at a stop after `reversals` (stations where it changes direction):
    /// turned round after an odd number of them.
    public func turned(after reversals: [String]) -> CoachSequence {
        var sequence = self
        sequence.reversals = reversals
        guard reversals.count % 2 == 1 else { return sequence }
        sequence.coaches = coaches.reversed().enumerated().map { index, coach in
            var coach = coach
            coach.id = index
            coach.drawing?.turned.toggle()
            return coach
        }
        return sequence
    }

    /// bahn.de's sequence with the drawings of vagonweb's plan (`plan` as vagonweb has it, not turned),
    /// when it is the same train: the same coaches by number, in the plan's order or the other way
    /// round. Nil when the train differs from the plan, so no coach gets another coach's drawing.
    public func withDrawings(from plan: CoachSequence) -> CoachSequence? {
        let numbers = coaches.map(\.number)
        let planned = plan.coaches.map(\.number)
        guard !coaches.isEmpty, plan.coaches.allSatisfy({ $0.drawing != nil }), numbers.contains(where: { $0 != nil }) else { return nil }
        let drawings: [Coach.Drawing?]
        if numbers == planned {
            drawings = plan.coaches.map(\.drawing)
        } else if numbers == planned.reversed() {
            drawings = plan.coaches.reversed().map { coach in
                var drawing = coach.drawing
                drawing?.turned.toggle()
                return drawing
            }
        } else {
            return nil
        }
        var sequence = self
        for index in sequence.coaches.indices { sequence.coaches[index].drawing = drawings[index] }
        return sequence
    }

    /// Every coach has vagonweb's drawing, so the whole train can be drawn.
    public var isDrawn: Bool { !coaches.isEmpty && coaches.allSatisfy { $0.drawing != nil } }
}

extension CoachSequence.Coach.Kind {
    /// From bahn.de's vehicle category, e.g. "PASSENGERCARRIAGE_FIRST_CLASS", "HALFDININGCAR_ECONOMY_CLASS".
    init(category: String?) {
        let category = category ?? ""
        self = if category.hasPrefix("LOCOMOTIVE") { .locomotive }
            else if category.hasPrefix("POWERCAR") { .powerCar }
            else if category.hasPrefix("HALFDININGCAR") { .halfDiningCar }
            else if category.hasPrefix("DININGCAR") { .diningCar }
            else if category.contains("SLEEPER") { .sleeper }
            else if category.contains("COUCHETTE") { .couchette }
            else if category.hasPrefix("PASSENGERCARRIAGE") || category.hasPrefix("CONTROLCAR") || category.hasPrefix("DOUBLEDECK") { .passenger }
            else { .other }
    }
}

extension BahnDeClient {
    static func coachSequence(from response: SequenceResponse, category: String, number: Int?,
                              coupledNumbers: Set<Int> = []) -> CoachSequence {
        // Trains coupled to it for the whole ride are just as much the train asked for.
        let wanted = coupledNumbers.union([number].compactMap(\.self))
        let groups = requestedTrainGroups(response.groups ?? [], wanted: wanted)
        let requestedNumbers = Set(groups.compactMap(\.transport?.number))
        // Without train numbers every group counts as the requested train.
        let isRequested = { (group: SequenceResponse.Group) in
            requestedNumbers.contains(number ?? -1) ? group.transport?.number.map(wanted.contains) ?? false : true
        }

        let platform = response.platform
        // Positions are given along the platform; measure them from its start.
        let offset = platform?.start ?? 0

        var outGroups: [CoachSequence.Group] = []
        var coaches: [CoachSequence.Coach] = []
        for group in groups {
            let groupName = group.name ?? ""
            let unitNumber = hasTrainsets(category) ? unitNumber(from: groupName) : nil
            let trainName = group.transport.flatMap { transport in
                transport.number.map { "\(transport.category ?? category) \($0)" }
            }
            outGroups.append(CoachSequence.Group(
                trainName: trainName,
                destination: group.transport?.destination?.name,
                unit: unitNumber.map { TrainFormation.Unit(model: nil, number: $0, name: trainsetName(from: groupName)) },
                isRequestedTrain: isRequested(group)))
            for vehicle in group.vehicles ?? [] {
                let kind = CoachSequence.Coach.Kind(category: vehicle.type?.category)
                let typeCategory = vehicle.type?.category ?? ""
                let amenities = (vehicle.amenities ?? []).filter { !["NOT_AVAILABLE", "UNAVAILABLE"].contains($0.status ?? "") }
                coaches.append(CoachSequence.Coach(
                    id: coaches.count,
                    number: kind == .locomotive || kind == .powerCar ? nil : vehicle.wagonIdentificationNumber.map(String.init),
                    kind: kind,
                    firstClass: vehicle.type?.hasFirstClass ?? typeCategory.contains("FIRST"),
                    secondClass: vehicle.type?.hasEconomyClass ?? typeCategory.contains("ECONOMY"),
                    closed: vehicle.status == "CLOSED",
                    amenities: CoachSequence.Coach.Amenity.allCases.filter { amenity in amenities.contains { $0.type == amenity.rawValue } },
                    bikeSpaces: amenities.first { $0.type == CoachSequence.Coach.Amenity.bikeSpace.rawValue }?.amount.flatMap { $0 > 0 ? $0 : nil },
                    start: vehicle.platformPosition?.start.map { $0 - offset },
                    end: vehicle.platformPosition?.end.map { $0 - offset },
                    sector: vehicle.platformPosition?.sector,
                    group: outGroups.count - 1))
            }
        }

        // bahn.de lists the coaches from the front of the train, so it leaves towards whichever end
        // of the platform the first coach stands nearer to.
        var towardsEnd: Bool?
        if let first = coaches.first?.start, let last = coaches.last?.start, coaches.count > 1, first != last {
            towardsEnd = first > last
        }

        var length: Double?
        if let start = platform?.start, let end = platform?.end, end > start { length = end - start }
        let sectors = (platform?.sectors ?? []).compactMap { sector -> CoachSequence.Sector? in
            guard let name = sector.name, let start = sector.start, let end = sector.end else { return nil }
            return CoachSequence.Sector(name: name, start: start - offset, end: end - offset)
        }

        return CoachSequence(
            platform: response.departurePlatform ?? platform?.name,
            platformLength: length,
            sectors: sectors,
            groups: outGroups,
            coaches: coaches,
            travelsTowardsPlatformEnd: towardsEnd,
            differsFromSchedule: response.sequenceStatus == "DIFFERS_FROM_SCHEDULE",
            formation: formation(from: response, category: category, number: number, coupledNumbers: coupledNumbers))
    }
}
