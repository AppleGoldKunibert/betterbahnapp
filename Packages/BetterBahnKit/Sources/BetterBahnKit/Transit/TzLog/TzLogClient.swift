import Foundation

/// One train a trainset (Tz) ran as on a day, from our server's Tz log (#502, `Server/bahnde-proxy/tzlog.py`).
public struct TzRun: Codable, Sendable, Hashable, Identifiable {
    /// Calendar day in Germany, `yyyy-MM-dd`.
    public var day: String
    /// "ICE", "IC".
    public var category: String
    public var number: Int
    /// The station whose departure board showed the train, e.g. "Berlin Hbf".
    public var station: String?
    public var destination: String?
    /// bahn.de's `sequenceStatus`: "DIFFERS_FROM_SCHEDULE" when the Tz is not the planned one.
    public var status: String?

    public init(day: String, category: String, number: Int, station: String? = nil, destination: String? = nil,
                status: String? = nil) {
        self.day = day
        self.category = category
        self.number = number
        self.station = station
        self.destination = destination
        self.status = status
    }

    /// Today's calendar day in Germany, written like `day`.
    public static func day(of date: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public var id: String { "\(day)|\(category)|\(number)" }
    /// "ICE 597".
    public var trainName: String { "\(category) \(number)" }
    public var changedFromPlan: Bool { status == "DIFFERS_FROM_SCHEDULE" }

    /// The day as a date at noon in Germany.
    public var date: Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// A trainset (Tz) in the Tz list with the trains of its latest day.
public struct TzUnit: Codable, Sendable, Hashable, Identifiable {
    /// Without leading zeros, "8043".
    public var tz: String
    /// bahn.de's group name, "ICE8043" or "ICD4886" (IC 2 Twindexx).
    public var unit: String
    /// The vehicles' construction types ("I4080"), which tell the series.
    public var types: [String]
    public var lastDay: String
    public var trains: [TzRun]

    public var id: String { tz }
    public var number: Int? { Int(tz) }

    /// The series, e.g. "ICE 4", "ICE 3neo", "IC 2 Twindexx"; nil when the types don't say.
    public var series: String? {
        let category = unit.hasPrefix("ICD") ? "IC" : "ICE"
        return BahnDeClient.model(constructionTypes: types, groupName: unit, category: category)
            .map(TravelCollection.seriesName(of:))
    }

    /// The Taufname ("Freiburg im Breisgau") of an ICE trainset that has one.
    public var name: String? { number.flatMap { TrainsetNames.byUnit[$0] } }
    /// The special livery of the trainset, if it wears one.
    public var livery: String? { number.flatMap { TrainsetLiveries.byUnit[$0] } }
}

/// Our server's Tz log: every ICE/IC trainset in Germany, Switzerland, the Netherlands and Austria with
/// the trains it ran today and on each day of the last year (#502). The server collects it from bahn.de's
/// Wagenreihung; the app only reads it.
public struct TzLogClient: Sendable {
    let http: HTTPClient
    let auth: WorkerAuth?
    let baseURL: URL?

    public init(http: HTTPClient = HTTPClient(timeout: 15), auth: WorkerAuth? = nil, baseURL: URL? = BahnDeProxy.baseURL) {
        self.http = http
        self.auth = http.workerAuth(auth)
        self.baseURL = baseURL
    }

    struct ListResponse: Decodable { var units: [TzUnit] }
    struct HistoryResponse: Decodable { var trains: [TzRun] }

    /// Every Tz seen so far, ordered by number.
    public func units() async throws -> [TzUnit] {
        let answer: ListResponse = try await http.get(try url("tz/list"), as: ListResponse.self, auth: auth)
        return answer.units
    }

    /// The trains one Tz ran, newest day first.
    public func history(of tz: String) async throws -> [TzRun] {
        let answer: HistoryResponse = try await http.get(try url("tz/history", query: [.init(name: "tz", value: tz)]),
                                                         as: HistoryResponse.self, auth: auth)
        return answer.trains
    }

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let baseURL else { throw TransitError.notFound(path) }
        return query.isEmpty ? baseURL.appending(path: path) : baseURL.appending(path: path).appending(queryItems: query)
    }
}
