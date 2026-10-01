import Foundation

/// A connection someone shared from the DB Navigator app or bahn.de, as far as the share describes it.
public struct SharedConnection: Sendable, Hashable {
    public struct Leg: Sendable, Hashable {
        /// As DB spells it, e.g. "ICE 1502" or just "89687" for a train shared without its category.
        public var trainName: String
        public var origin: Station
        public var destination: Station
        public var departure: Date
        public var arrival: Date
    }

    public var origin: Station
    public var destination: Station
    public var departure: Date
    public var arrival: Date?
    /// Every train ridden, in order. Empty when the share only describes start and end (bahn.de's
    /// text names just the first and the last train, see `firstTrain`/`lastTrain`).
    public var legs: [Leg]
    public var firstTrain: String?
    public var lastTrain: String?
}

/// Reads connections shared from the DB Navigator app or bahn.de, and carries them into the app
/// through a `betterbahn://import` link (the share extension can't resolve them itself).
///
/// Both share a "Verbindung ansehen" link with a `vbid` that bahn.de resolves into every leg with
/// station IDs, so that is used whenever there is one; the text itself is only the fallback.
public enum DBShare {
    private static let scheme = "betterbahn"
    private static let importHost = "import"

    /// Whether `text` looks like a shared DB connection at all.
    public static func isConnection(_ text: String) -> Bool {
        vbid(in: text) != nil || connection(fromText: text) != nil
    }

    // MARK: App link

    public static func appURL(for text: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = importHost
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url
    }

    /// The shared text carried by `url`, or `nil` if it isn't an import link.
    public static func text(fromAppURL url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == importHost,
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: vbid

    /// The connection ID from a "Verbindung ansehen" link, e.g.
    /// `https://www.bahn.de/buchung/start?vbid=aaae3fa2%2D4333%2D…` (DB Navigator percent-encodes the dashes).
    public static func vbid(in text: String) -> String? {
        guard let match = text.firstMatch(of: /vbid=([0-9A-Za-z%\-]+)/),
              let decoded = String(match.1).removingPercentEncoding?.lowercased(),
              decoded.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil
        else { return nil }
        return decoded
    }

    /// Legs of a bahn.de "recon" string, e.g.
    /// `¶HKI¶T$A=1@O=Stuttgart Hbf@X=9182760@Y=48784782@L=8000096@a=128@$A=1@O=Nürnberg Hbf@…@$202609261657$202609261921$            89687$$1$…§T$…¶KC¶…`
    /// – legs separated by "§", each `kind$from$to$departure$arrival$train$…`. Legs without a train
    /// (walks between stations) are left out.
    static func legs(fromRecon recon: String) -> [SharedConnection.Leg]? {
        guard let start = recon.range(of: "¶HKI¶") else { return nil }
        let body = recon[start.upperBound...].prefix { $0 != "¶" }
        var legs: [SharedConnection.Leg] = []
        for section in body.split(separator: "§") {
            let fields = section.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > 5 else { return nil }
            let train = collapsingSpaces(fields[5])
            guard !train.isEmpty else { continue }
            guard let origin = station(fromReconLocation: fields[1]),
                  let destination = station(fromReconLocation: fields[2]),
                  let departure = reconDate(fields[3]), let arrival = reconDate(fields[4])
            else { return nil }
            legs.append(.init(trainName: train, origin: origin, destination: destination,
                              departure: departure, arrival: arrival))
        }
        return legs.isEmpty ? nil : legs
    }

    /// `A=1@O=Stuttgart Hbf@X=9182760@Y=48784782@L=8000096@a=128@` – coordinates in microdegrees.
    private static func station(fromReconLocation location: String) -> Station? {
        var values: [String: String] = [:]
        for pair in location.split(separator: "@") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let name = values["O"] else { return nil }
        let eva = values["L"]
        var coordinate: Coordinate?
        if let x = values["X"].flatMap(Double.init), let y = values["Y"].flatMap(Double.init) {
            coordinate = Coordinate(latitude: y / 1_000_000, longitude: x / 1_000_000)
        }
        return Station(id: eva ?? name, name: name, coordinate: coordinate, evaNumber: eva, source: .bahnDe)
    }

    private static func reconDate(_ string: String) -> Date? {
        guard string.count == 12, let value = Int(string) else { return nil }
        var components = DateComponents()
        components.year = value / 100_000_000
        components.month = value / 1_000_000 % 100
        components.day = value / 10_000 % 100
        components.hour = value / 100 % 100
        components.minute = value % 100
        return berlinCalendar.date(from: components)
    }

    // MARK: Text

    /// Parses the text itself, in either of the two formats:
    ///
    /// DB Navigator (every leg, stations by name):
    /// ```
    /// Schaffhausen → Berlin Hbf
    /// 27.09.2026
    ///
    /// IC 488
    /// Nach Stuttgart Hbf
    /// Ab 12:16 Schaffhausen, Gleis 4
    /// An 14:43 Stuttgart Hbf, Gleis 3
    /// …
    /// ```
    /// bahn.de (only start and end):
    /// ```
    /// Verbindung am Sa. 26.09.2026
    /// • von Stuttgart Hbf, Abfahrt 16:57 Uhr Gl. 16 mit 89687
    /// • nach Berlin Hbf, Ankunft 22:22 Uhr Gl. 5 mit ICE 1502
    /// ```
    public static func connection(fromText text: String) -> SharedConnection? {
        guard let day = shareDay(in: text) else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "•"))) }
        return navigatorConnection(lines: lines, day: day) ?? webConnection(lines: lines, day: day)
    }

    private static func navigatorConnection(lines: [String], day: DateComponents) -> SharedConnection? {
        var clock = Clock(day: day)
        var legs: [SharedConnection.Leg] = []
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard let departure = lines[index].wholeMatch(of: /Ab (\d{1,2}):(\d{2}) (.+)/),
                  index + 1 < lines.count,
                  let arrival = lines[index + 1].wholeMatch(of: /An (\d{1,2}):(\d{2}) (.+)/)
            else { continue }
            // The train sits above the "Ab" line, possibly with a "Nach <direction>" line in between.
            let above = lines[..<index].reversed().first { !$0.isEmpty && !$0.hasPrefix("Nach ") }
            let train = above.flatMap { $0.hasPrefix("An ") ? nil : collapsingSpaces($0) } ?? ""
            guard let departureTime = clock.next(hour: departure.1, minute: departure.2),
                  let arrivalTime = clock.next(hour: arrival.1, minute: arrival.2) else { return nil }
            index += 1
            if train.localizedCaseInsensitiveContains("Fußweg") { continue }
            legs.append(.init(trainName: train,
                              origin: namedStation(withoutPlatform(departure.3)),
                              destination: namedStation(withoutPlatform(arrival.3)),
                              departure: departureTime, arrival: arrivalTime))
        }
        guard let first = legs.first, let last = legs.last else { return nil }
        return SharedConnection(origin: first.origin, destination: last.destination, departure: first.departure,
                                arrival: last.arrival, legs: legs, firstTrain: first.trainName, lastTrain: last.trainName)
    }

    private static func webConnection(lines: [String], day: DateComponents) -> SharedConnection? {
        let from = lines.lazy.compactMap { $0.wholeMatch(of: /von (.+), Abfahrt (\d{1,2}):(\d{2}) Uhr(.*)/) }.first
        let to = lines.lazy.compactMap { $0.wholeMatch(of: /nach (.+), Ankunft (\d{1,2}):(\d{2}) Uhr(.*)/) }.first
        var clock = Clock(day: day)
        guard let from, let to, let departure = clock.next(hour: from.2, minute: from.3),
              let arrival = clock.next(hour: to.2, minute: to.3) else { return nil }
        return SharedConnection(origin: namedStation(String(from.1)), destination: namedStation(String(to.1)),
                                departure: departure, arrival: arrival, legs: [],
                                firstTrain: train(after: from.4), lastTrain: train(after: to.4))
    }

    /// " Gl. 16 mit ICE 1502" -> "ICE 1502"
    private static func train(after rest: Substring) -> String? {
        guard let match = rest.firstMatch(of: /mit (.+)/) else { return nil }
        let name = collapsingSpaces(String(match.1))
        return name.isEmpty ? nil : name
    }

    /// The travel day, "27.09.2026" or "Verbindung am Sa. 26.09.2026".
    private static func shareDay(in text: String) -> DateComponents? {
        guard let match = text.firstMatch(of: /(\d{1,2})\.(\d{1,2})\.(\d{4})/),
              let day = Int(match.1), let month = Int(match.2), let year = Int(match.3) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// Turns the times of a share, listed in travel order, into dates – a time earlier than the one
    /// before it means the ride went past midnight.
    private struct Clock {
        var day: DateComponents
        var last: Date?

        mutating func next(hour: Substring, minute: Substring) -> Date? {
            guard let hour = Int(hour), let minute = Int(minute) else { return nil }
            var components = day
            components.hour = hour
            components.minute = minute
            guard var date = DBShare.berlinCalendar.date(from: components) else { return nil }
            while let last, date < last {
                date = DBShare.berlinCalendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            last = date
            return date
        }
    }

    /// "Schaffhausen, Gleis 4" -> "Schaffhausen"
    private static func withoutPlatform(_ text: Substring) -> String {
        text.replacing(/,\s*(Gleis|Gl\.|Steig|Bahnsteig).*$/, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// A station known only by name; `DBShareImporter` looks it up before routing.
    private static func namedStation(_ name: String) -> Station {
        Station(id: name, name: name, coordinate: nil, evaNumber: nil, source: .bahnDe)
    }

    /// "ICE          1502" -> "ICE 1502"
    private static func collapsingSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let berlinCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
}

extension BahnDeClient {
    struct SharedConnectionResponse: Decodable {
        var hinfahrtRecon: String
    }

    /// Every leg of the connection behind a "Verbindung ansehen" link's `vbid`.
    public func sharedConnection(vbid: String) async throws -> SharedConnection {
        let url = Self.baseURL.appending(path: "angebote/verbindung/\(vbid)")
        let response = try await get(url, as: SharedConnectionResponse.self)
        guard let legs = DBShare.legs(fromRecon: response.hinfahrtRecon),
              let first = legs.first, let last = legs.last
        else { throw TransitError.decoding("Verbindung \(vbid)") }
        return SharedConnection(origin: first.origin, destination: last.destination, departure: first.departure,
                                arrival: last.arrival, legs: legs, firstTrain: first.trainName, lastTrain: last.trainName)
    }
}
