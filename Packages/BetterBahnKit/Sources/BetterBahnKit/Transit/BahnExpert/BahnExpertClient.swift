import Foundation

/// Result of a bahn.expert train-type lookup for one train on one calendar day.
public struct TrainTypeLookup: Codable, Sendable, Hashable {
    public enum FormationStatus: String, Codable, Sendable {
        /// The formation is the timetable's plan (`Planwagenreihung`), not a live assignment.
        case planned
        /// Live data from the operator. The actual vehicles may differ from the plan.
        case realtime
    }

    public struct Group: Codable, Sendable, Hashable {
        /// bahn.expert's series label, e.g. "ICE 4 Lang (BR412)".
        public var seriesName: String?
        /// Baureihe number, e.g. "412".
        public var baureihe: String?
        /// Triebzug number (only present for live data), e.g. "9465".
        public var unitNumber: String?
        public var origin: String?
        public var destination: String?
        public var coachCount: Int

        /// Marketing family: "ICE 1", "ICE 2", "ICE 3", "ICE 3neo", "ICE 4", "ICE T", "ICE L", or the
        /// cleaned-up bahn.expert name for anything else (e.g. "IC 2").
        public var family: String? {
            switch baureihe {
            case "401": "ICE 1"
            case "402": "ICE 2"
            case "403", "406", "407": "ICE 3"
            case "408": "ICE 3neo"
            case "411", "415": "ICE T"
            case "412": "ICE 4"
            default: seriesName.map(TrainTypeLookup.family(of:))
            }
        }
    }

    public var category: String
    public var number: String
    /// Calendar day (Europe/Berlin) as `yyyy-MM-dd`.
    public var date: String
    public var administration: String
    public var groups: [Group]
    public var status: FormationStatus
    /// Where the data came from, e.g. "DB-plan".
    public var source: String?
    public var retrievedAt: Date

    /// Distinct marketing families in order, e.g. ["ICE 4"] — "ICE 4 Lang (BR412)" collapses to "ICE 4".
    /// Live Tz numbers mark redesigned ICE 3neo ("ICE 3neo Redesign").
    public var families: [String] {
        var result: [String] = []
        for family in groups.compactMap({ TrainModel.name($0.family, unit: $0.unitNumber) }) where !result.contains(family) {
            result.append(family)
        }
        return result
    }

    /// "ICE 4" or "ICE 3neo + ICE 4"; nil if bahn.expert knows no series.
    public var summary: String? { families.isEmpty ? nil : families.joined(separator: " + ") }

    /// Names a Tz, which only live data does (and only it tells a redesigned ICE 3neo apart).
    public var hasUnitNumbers: Bool { groups.contains { $0.unitNumber != nil } }

    /// Adapter for the formation UI; adds the Taufname for live Tz numbers.
    public var formation: TrainFormation {
        TrainFormation(units: groups.map { group in
            .init(model: TrainModel.name(group.family, unit: group.unitNumber), number: group.unitNumber,
                  name: group.unitNumber.flatMap(Int.init).flatMap { TrainsetNames.byUnit[$0] })
        })
    }

    /// Strips the variant and the parenthesised class: "ICE 4 Lang (BR412)" → "ICE 4", "ICE 3neo (BR408)" → "ICE 3neo".
    static func family(of seriesName: String) -> String {
        var name = seriesName
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        name = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" Lang", " Kurz"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        return name
    }
}

/// bahn.expert's public API, used only as the fallback for the train type when bahn.de's coach
/// sequence has nothing: it has DB's planned formation (`DB-plan`) for days ahead, which bahn.de only
/// has for the coming hours.
/// Given category, number and date it resolves the journey, finds the first stop and asks for the
/// coach sequence there — what bahn.expert's own web page does.
public struct BahnExpertClient: Sendable {
    public static let baseURL = URL(string: "https://bahn.expert")!

    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient(timeout: 12)) {
        self.http = http
    }

    // MARK: Wire types

    struct Envelope<T: Decodable>: Decodable { var json: T }

    struct FoundJourney: Decodable {
        struct Train: Decodable { var category: String?; var journeyNumber: Int? }
        var journeyId: String
        var train: Train?
    }

    struct Details: Decodable {
        struct Stop: Decodable {
            struct Place: Decodable { var evaNumber: String }
            struct Event: Decodable { var scheduledTime: Date }
            var stopPlace: Place
            var departure: Event?
        }
        struct Train: Decodable { var admin: String? }
        var stops: [Stop]
        var train: Train?
    }

    struct SequenceResponse: Decodable {
        struct Sequence: Decodable {
            struct Group: Decodable {
                struct Baureihe: Decodable { var identifier: String?; var baureihe: String?; var name: String? }
                struct Coach: Decodable {}
                var name: String?
                var originName: String?
                var destinationName: String?
                var journeyNumber: Int?
                var baureihe: Baureihe?
                var coaches: [Coach]?
            }
            var groups: [Group]
        }
        var isRealtime: Bool
        var source: String?
        var sequence: Sequence?
    }

    // MARK: Lookup

    /// - Parameters:
    ///   - category: e.g. "ICE".
    ///   - number: e.g. "2374".
    ///   - date: calendar day of the train's *initial* departure, `yyyy-MM-dd`.
    /// - Returns: nil if bahn.expert knows the train but has no coach sequence for it.
    /// - Throws: `TransitError.notFound` if no such journey exists on that day.
    public func trainType(category: String, number: String, date: String,
                          administration: String = BahnDeClient.dbAdministration) async throws -> TrainTypeLookup? {
        let category = category.uppercased()
        guard let journeyNumber = Int(number), Self.isValidDay(date) else {
            throw TransitError.invalidInput("Zugnummer oder Datum ungültig.")
        }
        let found: [FoundJourney] = try await call("journey/find", input: [
            "json": [
                "journeyNumber": journeyNumber, "administration": administration, "category": category,
                "initialDepartureDate": "\(date)T12:00:00.000Z", "withOEV": true, "limit": 1,
            ] as [String: Any],
            "meta": [["date", "initialDepartureDate"]],
        ])
        // A journey ID can resolve to a different train than asked for, so verify what came back.
        guard let journey = found.first(where: {
            $0.train?.journeyNumber == journeyNumber && $0.train?.category?.uppercased() == category
        }) else { throw TransitError.notFound("\(category) \(number)") }

        let details: Details = try await call("journey/detailsByJourneyId", input: ["json": journey.journeyId])
        guard let firstStop = details.stops.first, let departure = firstStop.departure?.scheduledTime else { return nil }

        // Live data is keyed by the administration that runs the train, which can differ from the
        // one searched (e.g. an ICE run by SBB inside Switzerland).
        let runningAdministration = details.train?.admin ?? administration
        let plannedDeparture = JSONDecoding.isoString(departure)
        let sequenceResponse: SequenceResponse = try await call("coachSequence/departureSequence", input: [
            "json": [
                "evaNumber": firstStop.stopPlace.evaNumber, "plannedDeparture": plannedDeparture,
                "initialDeparture": plannedDeparture, "journeyNumber": journeyNumber,
                "category": category, "administration": runningAdministration,
            ],
            "meta": [["date", "plannedDeparture"], ["date", "initialDeparture"]],
        ])
        guard let sequence = sequenceResponse.sequence, !sequence.groups.isEmpty else { return nil }

        // Split trains (e.g. ICE 950 + ICE 940 coupled up to Hamm) list every half; keep the ones that
        // run as the requested train so the other half's series doesn't leak in.
        let own = sequence.groups.filter { $0.journeyNumber == journeyNumber }
        let groups = (own.isEmpty ? sequence.groups : own).map { group in
            let seriesName = Self.seriesName(of: group, category: category)
            return TrainTypeLookup.Group(
                seriesName: seriesName, baureihe: group.baureihe?.baureihe,
                unitNumber: sequenceResponse.isRealtime ? Self.unitNumber(of: group, seriesName: seriesName, category: category) : nil,
                origin: group.originName, destination: group.destinationName, coachCount: group.coaches?.count ?? 0)
        }
        return TrainTypeLookup(category: category, number: number, date: date, administration: administration,
                               groups: groups, status: sequenceResponse.isRealtime ? .realtime : .planned,
                               source: sequenceResponse.source, retrievedAt: .now)
    }

    /// Looks up a leg's train on the day it departs (Berlin time). Only DB long-distance categories.
    public func trainType(for leg: Leg) async throws -> TrainTypeLookup? {
        guard let ref = BahnDeClient.trainReference(for: leg.line) else { return nil }
        return try await trainType(category: ref.category, number: ref.number, date: BahnDeClient.berlinDay(leg.departure.planned))
    }

    // MARK: Helpers

    /// bahn.expert's series name; for IC 2 Twindexx sets ("ICD2868") it has none, only the group name
    /// says what it is (as in bahn.de's `model(constructionTypes:groupName:category:)`).
    static func seriesName(of group: SequenceResponse.Sequence.Group, category: String) -> String? {
        if let name = group.baureihe?.name { return name }
        if category == "IC" || category == "EC", group.name?.hasPrefix("ICD") == true { return "IC 2 Twindexx" }
        return nil
    }

    /// The Tz from the group name ("ICE9465"). A loco-hauled IC 1 has a coach-set number there instead
    /// ("IC450007", as in bahn.de's `isIC1`). bahn.expert has no vehicle numbers to tell it apart, and no
    /// Baureihe for IC 2 sets either, so only an IC without any series and a number longer than any Tz counts.
    static func unitNumber(of group: SequenceResponse.Sequence.Group, seriesName: String?, category: String) -> String? {
        guard let number = group.name.flatMap(BahnDeClient.unitNumber(from:)) else { return nil }
        let isIC1 = (category == "IC" || category == "EC") && group.baureihe?.baureihe == nil
            && (seriesName.map(TrainTypeLookup.family(of:)).map { $0 == "IC 1" } ?? true) && number.count > 4
        return isIC1 ? nil : number
    }

    /// Rejects malformed dates and impossible ones like 2026-02-31.
    static func isValidDay(_ day: String) -> Bool {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, day.count == 10 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// bahn.expert answers requests without a `Referer` from its own site with an empty `206`
    /// (it did not until 2026-09-20), so every call identifies where the API is meant to be used from.
    static func request(procedure: String, input: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/orpc/\(procedure)"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: input)
        return request
    }

    private func call<T: Decodable>(_ procedure: String, input: [String: Any]) async throws -> T {
        let request = try Self.request(procedure: procedure, input: input)
        do {
            return try await http.send(request, as: Envelope<T>.self).json
        } catch TransitError.http(let status, _) where status == 404 {
            throw TransitError.notFound(procedure)
        }
    }
}
