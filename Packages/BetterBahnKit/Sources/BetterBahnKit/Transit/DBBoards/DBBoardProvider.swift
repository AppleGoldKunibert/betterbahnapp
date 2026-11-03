import Foundation

/// A station's departures or arrivals from DB, asked before Transitous (`CombinedProvider.dbBoards`): trains from
/// DB Timetables (IRIS, what bahn.expert's boards show, `TimetablesClient.boardStops`), buses, trams and subways
/// from RIS::Boards through our server (`RISBoardsClient`). A stop IRIS doesn't know (a bus stop, a station
/// abroad) gets everything from RIS::Boards. Throws `notFound` when DB has nothing, so Transitous answers.
///
/// Entries carry the source `.bahnDe`. Their trip IDs are RIS journey IDs (RIS::Boards) or `iris|…` references to a
/// train by category, number, stop and planned time (`IRISTripReference`), resolved when the trip is opened
/// (`RISRoutingProvider.trip(id:)`).
public struct DBBoardProvider: Sendable {
    let timetables: TimetablesClient
    let boards: RISBoardsClient?

    public init(timetables: TimetablesClient = TimetablesClient(), boards: RISBoardsClient? = .shared) {
        self.timetables = timetables
        self.boards = boards
    }

    static let localProducts: Set<Product> = [.bus, .tram, .subway, .ferry, .other]

    public func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] {
        let end = date.addingTimeInterval(TimeInterval(duration * 60))
        let trains = products.contains { !Self.localProducts.contains($0) }
        let local = !products.isDisjoint(with: Self.localProducts)
        var entries: [BoardEntry] = []
        var irisAnswered = false
        if trains, let stops = try? await timetables.boardStops(at: station, kind: kind, from: date, to: end), !stops.isEmpty {
            irisAnswered = true
            entries += stops.map { Self.entry($0, kind: kind, station: station) }
        }
        // RIS::Boards for buses, trams and subways, and for everything at a stop IRIS doesn't know.
        var eva = station.evaNumber
        if eva == nil, local || !irisAnswered { eva = await timetables.boardEVA(for: station) }
        if let boards, local || !irisAnswered, let eva {
            let types = irisAnswered ? RISBoardsClient.localTypes : RISBoardsClient.localTypes + RISBoardsClient.trainTypes
            if let answer = try? await boards.board(kind, eva: eva, from: date, to: end, types: types) {
                entries += answer.map { Self.entry($0, kind: kind, station: station) }
            }
        }
        entries = entries.filter { products.contains($0.line.filterProduct) }
        guard !entries.isEmpty else { throw TransitError.notFound(station.displayName) }
        return entries.sorted { $0.time.planned < $1.time.planned }
    }

    // MARK: IRIS

    static func entry(_ found: TimetablesClient.BoardStop, kind: BoardKind, station: Station) -> BoardEntry {
        let stop = found.stop, event = found.event
        let category = stop.category ?? ""
        let number = stop.number ?? ""
        let line = line(category: category, number: number, lineName: stop.lineName)
        let planned = event.planned ?? event.actual ?? .now
        let reference = IRISTripReference(category: category, number: number, eva: found.eva, planned: planned, kind: kind)
        return BoardEntry(kind: kind, tripId: reference.id, station: station, line: line,
                          otherEnd: kind == .departures ? event.path.last : event.path.first,
                          time: TimeInfo(planned: planned, actual: event.actual),
                          platform: PlatformInfo(planned: event.plannedPlatform, actual: event.actualPlatform),
                          cancelled: event.cancelled,
                          terminatesOrOriginatesHere: kind == .departures ? stop.arrival == nil : stop.departure == nil,
                          remarks: TimetablesMessage.resolve(stop.messages).map(\.text), source: .bahnDe)
    }

    static let longDistance: Set<String> = ["ICE", "ECE", "TGV", "RJX", "FR", "IC", "EC", "RJ", "D", "WB", "NJ", "EN", "FLX", "IR", "ES", "EST"]

    /// Named like Transitous names the same train: "ICE 23", "RE1 (10933)" (number 10933), "S6".
    static func line(category: String, number: String, lineName: String?) -> Line {
        let upper = category.uppercased()
        let product = product(category: upper, lineName: lineName)
        if longDistance.contains(upper) || lineName?.isEmpty != false {
            return Line(name: "\(category) \(number)", number: number, product: product, operatorName: nil)
        }
        let line = lineName ?? category
        if product == .suburban || product == .bus {
            return Line(name: line, number: String(line.filter(\.isNumber)), product: product, operatorName: nil, tripNumber: number)
        }
        return Line(name: "\(line) (\(number))", number: number, product: product, operatorName: nil, tripNumber: number)
    }

    static func product(category: String, lineName: String?) -> Product {
        switch category {
        case "ICE", "ECE", "TGV", "RJX", "FR": return .highSpeed
        case "IC", "EC", "RJ", "D", "WB", "ES", "EST": return .longDistance
        case "NJ", "EN": return .nightTrain
        case "FLX", "IR": return .interregio
        case "S": return .suburban
        case "BUS", "SEV": return .bus
        default: break
        }
        let lineCategory = String((lineName ?? "").prefix { $0.isLetter }).uppercased()
        switch lineCategory {
        case "RE", "IRE", "REX": return .regionalExpress
        case "S": return .suburban
        case "BUS", "SEV": return .bus
        default: return .regional
        }
    }

    // MARK: RIS::Boards

    static func entry(_ item: RISBoardsClient.Item, kind: BoardKind, station: Station) -> BoardEntry {
        let line = RISRoutingProvider.line(item.transport.routing, operatorName: item.administration?.operatorName)
        let live = item.timeType != nil && item.timeType != "SCHEDULE"
        return BoardEntry(kind: kind, tripId: item.journeyID, station: station, line: line,
                          otherEnd: kind == .departures ? item.transport.destination?.name : item.transport.origin?.name,
                          time: TimeInfo(planned: item.timeSchedule, actual: live ? item.time : nil),
                          platform: PlatformInfo(planned: item.platformSchedule, actual: item.platform),
                          cancelled: item.canceled == true, terminatesOrOriginatesHere: nil,
                          remarks: (item.messages ?? []).compactMap(\.text), source: .bahnDe)
    }
}

/// A train on a DB Timetables board, as a trip ID: "iris|ICE|23|8000207|1793743920|d".
public struct IRISTripReference: Sendable, Hashable {
    public var category: String
    public var number: String
    public var eva: String
    public var planned: Date
    public var kind: BoardKind

    public var id: String {
        "iris|\(category)|\(number)|\(eva)|\(Int(planned.timeIntervalSince1970))|\(kind == .departures ? "d" : "a")"
    }

    public init(category: String, number: String, eva: String, planned: Date, kind: BoardKind) {
        self.category = category
        self.number = number
        self.eva = eva
        self.planned = planned
        self.kind = kind
    }

    public init?(id: String) {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "iris", let seconds = TimeInterval(parts[4]) else { return nil }
        self.init(category: parts[1], number: parts[2], eva: parts[3], planned: Date(timeIntervalSince1970: seconds),
                  kind: parts[5] == "a" ? .arrivals : .departures)
    }
}

/// DB's official RIS::Boards through our server (`Server/bahnde-proxy`, which adds the key): a station's departures
/// or arrivals with its group (the bus and tram stops at a railway station, "Breslauer Platz/Hauptbahnhof, Köln").
public struct RISBoardsClient: Sendable {
    static let path = "db/apis/ris-boards/v1/public/"
    static let localTypes = ["BUS", "TRAM", "SUBWAY", "FERRY", "SHUTTLE"]
    static let trainTypes = ["HIGH_SPEED_TRAIN", "INTERCITY_TRAIN", "INTER_REGIONAL_TRAIN", "REGIONAL_TRAIN", "CITY_TRAIN"]

    let baseURL: URL
    let http: HTTPClient
    let auth: WorkerAuth?

    /// The app's client: our server, on the app's real session; nil without a server.
    public static let shared: RISBoardsClient? = BahnDeProxy.baseURL.map { RISBoardsClient(serverURL: $0) }

    public init(serverURL: URL, http: HTTPClient = HTTPClient(timeout: 8), auth: WorkerAuth? = nil) {
        self.baseURL = serverURL.appending(path: Self.path)
        self.http = http
        self.auth = http.workerAuth(auth)
    }

    struct Response: Decodable {
        var departures: [Item]?
        var arrivals: [Item]?
    }

    struct Item: Decodable {
        var journeyID: String
        var timeSchedule: Date
        var time: Date?
        var timeType: String?
        var platform: String?
        var platformSchedule: String?
        var canceled: Bool?
        var messages: [Message]?
        var administration: Administration?
        var transport: Transport
        struct Message: Decodable { var text: String? }
        struct Administration: Decodable { var operatorName: String? }
        struct Place: Decodable { var name: String? }
        struct Transport: Decodable {
            var type: String?
            var category: String?
            var number: Int?
            var line: String?
            var label: String?
            var journeyDescription: String?
            var destination: Place?
            var origin: Place?

            /// The same transport as DB's routing describes it, to be named the same way.
            var routing: RISRoutingProvider.Transport {
                RISRoutingProvider.Transport(type: type, journeyDescription: journeyDescription, category: category, number: number,
                                             line: line, label: label, direction: nil)
            }
        }
    }

    func board(_ kind: BoardKind, eva: String, from start: Date, to end: Date, types: [String]) async throws -> [Item] {
        // "2026-11-04T12:00:00+01:00": Berlin time with its offset, as DB's own boards ask.
        let format = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: TimetablesClient.berlin)
        var items: [URLQueryItem] = [
            .init(name: "timeStart", value: start.formatted(format)), .init(name: "timeEnd", value: end.formatted(format)),
            .init(name: "includeStationGroup", value: "true"), .init(name: "maxTransportsPerType", value: "100"),
        ]
        items += types.map { .init(name: "filterTransports", value: $0) }
        var components = URLComponents(url: baseURL.appending(path: "\(kind == .departures ? "departures" : "arrivals")/\(eva)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // "+01:00" must reach DB as "%2B01:00", not as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw TransitError.invalidInput(eva) }
        let response = try await http.get(url, as: Response.self, headers: ["Accept": "application/vnd.de.db.ris+json"], auth: auth)
        return (kind == .departures ? response.departures : response.arrivals) ?? []
    }
}
