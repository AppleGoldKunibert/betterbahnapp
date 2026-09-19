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

    /// Public page the same data is shown on, so the user can verify or open it.
    public var pageURL: URL? { BahnExpertClient.pageURL(category: category, number: number, date: date, administration: administration) }

    /// Distinct marketing families in order, e.g. ["ICE 4"] — "ICE 4 Lang (BR412)" collapses to "ICE 4".
    public var families: [String] {
        var result: [String] = []
        for family in groups.compactMap({ $0.seriesName.map(TrainTypeLookup.family(of:)) }) where !result.contains(family) {
            result.append(family)
        }
        return result
    }

    /// "ICE 4" or "ICE 3neo + ICE 4"; nil if bahn.expert knows no series.
    public var summary: String? { families.isEmpty ? nil : families.joined(separator: " + ") }

    /// Adapter for the existing formation UI.
    public var formation: TrainFormation {
        TrainFormation(units: groups.map { .init(model: $0.seriesName.map(Self.family(of:)), number: $0.unitNumber) })
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

/// bahn.expert's public API. Given only category, number and date it resolves the journey, finds the
/// first stop and asks for the coach sequence there - what bahn.expert's own web page does, but
/// without a browser. Works for days ahead (planned formation), unlike bahn.de's coach sequence.
public struct BahnExpertClient: Sendable {
    public static let baseURL = URL(string: "https://bahn.expert")!
    /// Deutsche Bahn's administration ID.
    public static let dbAdministration = "80"

    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient(timeout: 12)) {
        self.http = http
    }

    public static func pageURL(category: String, number: String, date: String, administration: String = dbAdministration) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/details/\("\(category) \(number)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")/\(date)T12:00:00.000Z"
        components?.queryItems = [.init(name: "administration", value: administration)]
        return components?.url
    }

    // MARK: Wire types

    struct Envelope<T: Decodable>: Decodable { var json: T }

    struct FoundJourney: Decodable {
        struct Stop: Decodable { struct Place: Decodable { var evaNumber: String }; var stopPlace: Place }
        struct Train: Decodable { var category: String?; var journeyNumber: Int? }
        var journeyId: String
        var train: Train?
        var firstStop: Stop?
    }

    struct Details: Decodable {
        struct Stop: Decodable {
            struct Place: Decodable { var evaNumber: String }
            struct Event: Decodable { var scheduledTime: Date }
            var stopPlace: Place
            var departure: Event?
        }
        struct Train: Decodable { var category: String?; var journeyNumber: Int?; var admin: String? }
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
                          administration: String = BahnExpertClient.dbAdministration) async throws -> TrainTypeLookup? {
        let category = category.uppercased()
        guard let journeyNumber = Int(number), Self.isValidDay(date) else {
            throw TransitError.invalidInput("Zugnummer oder Datum ungültig.")
        }
        let noon = "\(date)T12:00:00.000Z"

        let found: [FoundJourney] = try await call("journey/find", input: [
            "json": [
                "journeyNumber": journeyNumber, "administration": administration, "category": category,
                "initialDepartureDate": noon, "withOEV": true, "limit": 1,
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

        let groups = sequence.groups.map { group in
            TrainTypeLookup.Group(
                seriesName: group.baureihe?.name, baureihe: group.baureihe?.baureihe,
                unitNumber: sequenceResponse.isRealtime ? Self.unitNumber(from: group.name) : nil,
                origin: group.originName, destination: group.destinationName, coachCount: group.coaches?.count ?? 0)
        }
        return TrainTypeLookup(category: category, number: number, date: date, administration: administration,
                               groups: groups, status: sequenceResponse.isRealtime ? .realtime : .planned,
                               source: sequenceResponse.source, retrievedAt: .now)
    }

    /// Looks up a leg's train on the day it departs (Berlin time). Only DB long-distance categories.
    public func trainType(for leg: Leg) async throws -> TrainTypeLookup? {
        guard let line = leg.line, let number = line.number,
              let category = line.name.split(separator: " ").first.map(String.init)?.uppercased(),
              ["ICE", "IC", "EC", "ECE"].contains(category) else { return nil }
        return try await trainType(category: category, number: number, date: Self.berlinDay(leg.departure.planned))
    }

    // MARK: Helpers

    /// Group names for live data look like "ICE9465"; planned ones like "373-planned".
    static func unitNumber(from groupName: String?) -> String? {
        guard let groupName else { return nil }
        let letters = groupName.prefix { $0.isLetter }
        let digits = groupName.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let trimmed = String(digits.drop { $0 == "0" })
        return trimmed.isEmpty ? nil : trimmed
    }

    static func berlinDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
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

    private func call<T: Decodable>(_ procedure: String, input: [String: Any]) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appending(path: "api/orpc/\(procedure)"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: input)
        do {
            return try await http.send(request, as: Envelope<T>.self).json
        } catch TransitError.http(let status, _) where status == 404 {
            throw TransitError.notFound(procedure)
        }
    }
}
