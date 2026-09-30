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
    /// Whether the train leaves towards the platform's end (the last sector); nil when unknown.
    public var travelsTowardsPlatformEnd: Bool?
    /// bahn.de says the sequence differs from the planned one (e.g. a trainset is missing or reversed).
    public var differsFromSchedule: Bool
    /// Series, Tz and Taufname of the requested train's trainsets.
    public var formation: TrainFormation

    /// Groups that run as another train with another destination than the requested one.
    public var hasOtherTrains: Bool { groups.contains { !$0.isRequestedTrain } }
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
    static func coachSequence(from response: SequenceResponse, category: String, number: Int?) -> CoachSequence {
        let groups = response.groups ?? []
        let requestedNumbers = Set(groups.compactMap(\.transport?.number))
        // Without train numbers every group counts as the requested train.
        let isRequested = { (group: SequenceResponse.Group) in
            requestedNumbers.contains(number ?? -1) ? group.transport?.number == number : true
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
            formation: formation(from: response, category: category, number: number))
    }
}
