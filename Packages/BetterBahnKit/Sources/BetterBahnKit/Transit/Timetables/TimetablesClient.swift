import Foundation
import Security

/// Credentials for the official DB "Timetables" API (developers.deutschebahn.com, API Marketplace,
/// free plan), the classic IRIS-based feed also used by e.g. bahn.de's own delay data.
public struct TimetablesCredentials: Codable, Sendable, Equatable {
    public var clientID: String
    public var apiKey: String

    public init(clientID: String, apiKey: String) {
        self.clientID = clientID
        self.apiKey = apiKey
    }

    public var isConfigured: Bool { !clientID.isEmpty && !apiKey.isEmpty }
}

/// Stores `TimetablesCredentials` in the Keychain, since (unlike the Träwelling client ID) the API
/// key is a real secret.
public struct TimetablesCredentialsStore: Sendable {
    let service: String
    let account: String

    public init(service: String = "de.betterbahn.timetables", account: String = "credentials") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> TimetablesCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TimetablesCredentials.self, from: data)
    }

    public func save(_ credentials: TimetablesCredentials) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// One `<ar>`/`<dp>` (arrival/departure) side of a stop, from either a `plan` response (planned
/// time/platform) or a `fchg` response (actual time/platform, cancellation).
struct TimetablesEvent {
    var planned: Date?
    var actual: Date?
    var plannedPlatform: String?
    var actualPlatform: String?
    var cancelled: Bool
}

/// One `<s>` (stop) element from a DB Timetables XML response. In `fchg`, most stops carry only
/// `id`/`eva` — no `<tl>` — since they're meant to be correlated back to a `plan` response by `id`;
/// only newly added trains (not in the original plan) carry their own `<tl>` there.
struct TimetablesStop {
    var id: String
    var category: String?
    var number: String?
    var arrival: TimetablesEvent?
    var departure: TimetablesEvent?
}

/// Overlay to apply onto a `Leg` once a matching `TimetablesStop` was found.
public struct TimetablesLegOverride: Sendable {
    public var departure: TimeInfo?
    public var departurePlatform: PlatformInfo?
    public var arrival: TimeInfo?
    public var arrivalPlatform: PlatformInfo?
    public var cancelled: Bool
}

/// Reads live delay, platform and cancellation data straight from Deutsche Bahn's own dispatching
/// feed (the "Timetables" API at apis.deutschebahn.com/db-api-marketplace, IRIS-based), since
/// Transitous' realtime coverage for DB long-distance trains can lag by many minutes or be missing
/// entirely. This API has no journey search of its own, and its `fchg` (full changes) endpoint only
/// lists actual times/platforms keyed by a stop `id` that a matching `plan` response defines — so
/// every lookup first finds the stop in `plan` (by category, train number and planned time) and then
/// looks up that same `id` in `fchg` for whatever changed. Used to overlay onto legs that already
/// came from another provider, not as a replacement for routing.
public struct TimetablesClient: Sendable {
    public static let baseURL = URL(string: "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1")!
    /// A stop only counts as a match when its planned time is this close to the leg's.
    static let matchTolerance: TimeInterval = 180
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    let http: HTTPClient
    let credentials: TimetablesCredentials
    let bahnDe: BahnDeClient

    public init(credentials: TimetablesCredentials, http: HTTPClient = HTTPClient(timeout: 6), bahnDe: BahnDeClient = BahnDeClient()) {
        self.credentials = credentials
        self.http = http
        self.bahnDe = bahnDe
    }

    private func get(path: String) async throws -> [TimetablesStop] {
        let url = Self.baseURL.appending(path: path)
        var request = URLRequest(url: url, timeoutInterval: http.timeout)
        request.setValue(credentials.clientID, forHTTPHeaderField: "DB-Client-Id")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "DB-Api-Key")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        let data = try await http.sendRaw(request)
        return TimetablesXMLParser.parse(data)
    }

    /// The hour-bucketed schedule (never carries delays) for `eva` around `time`.
    private func plan(eva: String, around time: Date) async throws -> [TimetablesStop] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.berlin
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: time)
        let date = String(format: "%02d%02d%02d", (components.year ?? 0) % 100, components.month ?? 0, components.day ?? 0)
        let hour = String(format: "%02d", components.hour ?? 0)
        return try await get(path: "plan/\(eva)/\(date)/\(hour)")
    }

    /// Every currently known change (delay, platform swap, cancellation) at `eva`, keyed by stop id.
    private func changes(eva: String) async throws -> [String: TimetablesStop] {
        let stops = try await get(path: "fchg/\(eva)")
        return Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func eva(for station: Station) async -> String? {
        if let eva = station.evaNumber { return eva }
        return try? await bahnDe.evaNumber(for: station)
    }

    /// The live event (actual time/platform/cancellation) for `category`+`number` at `eva`, on
    /// whichever `side` (arrival or departure) has a planned time within `matchTolerance` of `time`.
    private func liveEvent(eva: String, category: String, number: String, time: Date,
                            side: KeyPath<TimetablesStop, TimetablesEvent?>) async -> TimetablesEvent? {
        guard let planned = try? await plan(eva: eva, around: time),
              let stop = Self.match(planned, category: category, number: number, plannedTime: time, side: side) else { return nil }
        guard let changed = try? await changes(eva: eva)[stop.id] else { return nil }
        return changed[keyPath: side]
    }

    /// Live data for `leg`'s departure and arrival, matched by category, train number and planned
    /// time. Returns `nil` when nothing changed is known yet at either station, so callers should
    /// keep whatever schedule they already have.
    public func realtime(for leg: Leg) async -> TimetablesLegOverride? {
        guard credentials.isConfigured, !leg.isWalking, let line = leg.line, let number = line.number,
              let category = Self.category(from: line.name) else { return nil }

        var departure: TimeInfo?
        var departurePlatform: PlatformInfo?
        var arrival: TimeInfo?
        var arrivalPlatform: PlatformInfo?
        var cancelled = false

        if let eva = await eva(for: leg.origin),
           let event = await liveEvent(eva: eva, category: category, number: number, time: leg.departure.planned, side: \.departure) {
            departure = TimeInfo(planned: leg.departure.planned, actual: event.actual)
            if event.actualPlatform != nil {
                departurePlatform = PlatformInfo(planned: leg.departurePlatform?.planned, actual: event.actualPlatform)
            }
            if event.cancelled { cancelled = true }
        }

        if let eva = await eva(for: leg.destination),
           let event = await liveEvent(eva: eva, category: category, number: number, time: leg.arrival.planned, side: \.arrival) {
            arrival = TimeInfo(planned: leg.arrival.planned, actual: event.actual)
            if event.actualPlatform != nil {
                arrivalPlatform = PlatformInfo(planned: leg.arrivalPlatform?.planned, actual: event.actualPlatform)
            }
            if event.cancelled { cancelled = true }
        }

        guard departure != nil || arrival != nil else { return nil }
        return TimetablesLegOverride(departure: departure, departurePlatform: departurePlatform,
                                      arrival: arrival, arrivalPlatform: arrivalPlatform, cancelled: cancelled)
    }

    /// Every scheduled departure/arrival at `station` matching `category` (optional, case-insensitive)
    /// and `number`, across the requested window – straight from DB's own dispatching plan (`/plan`),
    /// which lists every train by its real category and number regardless of how any particular
    /// journey-planning feed brands or names it. Used to confirm a user-named train really exists and
    /// find its true scheduled time when another provider's board doesn't carry it under a matching
    /// name (different branding – e.g. an ÖBB "RJ" that DB's own feed calls "ICE" – or misses the
    /// departure from its board data entirely): see `TrainRoutePlanner`'s use of this for "Bestimmter
    /// Zug". Returns an empty array (rather than throwing) on any failure, since this is always a
    /// best-effort supplement to another provider's board, never the primary source.
    public func scheduledTimes(category: String?, number: String, at station: Station,
                               from: Date, duration: Int) async -> [Date] {
        guard credentials.isConfigured, let eva = await eva(for: station) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.berlin
        let end = from.addingTimeInterval(TimeInterval(duration * 60))
        var hours: [Date] = []
        var cursor = from
        // `/plan` is bucketed by hour; cap the pagination so a generous window (e.g. the custom-train
        // picker's default 8h) can't fire dozens of concurrent requests.
        repeat {
            hours.append(cursor)
            cursor = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? cursor.addingTimeInterval(3600)
        } while cursor < end && hours.count < 10

        let stops = await withTaskGroup(of: [TimetablesStop].self) { group in
            for hour in hours {
                group.addTask { (try? await self.plan(eva: eva, around: hour)) ?? [] }
            }
            var all: [TimetablesStop] = []
            for await page in group { all += page }
            return all
        }

        let wantedCategory = category?.uppercased()
        return stops
            .filter { stop in
                (wantedCategory == nil || stop.category?.uppercased() == wantedCategory)
                    && stop.number.map { Self.sameNumber($0, number) } == true
            }
            .compactMap { ($0.departure ?? $0.arrival)?.planned }
            .filter { $0 >= from.addingTimeInterval(-60) && $0 <= end }
            .sorted()
    }

    /// "ICE 571" -> "ICE".
    static func category(from lineName: String) -> String? {
        lineName.split(separator: " ").first.map(String.init)?.uppercased()
    }

    static func match(_ stops: [TimetablesStop], category: String, number: String, plannedTime: Date,
                       side: KeyPath<TimetablesStop, TimetablesEvent?>) -> TimetablesStop? {
        stops
            .filter { ($0.category?.uppercased() == category) && $0.number.map { Self.sameNumber($0, number) } == true }
            .compactMap { stop -> (TimetablesStop, TimeInterval)? in
                guard let planned = stop[keyPath: side]?.planned else { return nil }
                return (stop, abs(planned.timeIntervalSince(plannedTime)))
            }
            .min { $0.1 < $1.1 }
            .flatMap { $0.1 <= matchTolerance ? $0.0 : nil }
    }

    /// IRIS train numbers sometimes carry leading zeros; compare numerically when possible.
    static func sameNumber(_ a: String, _ b: String) -> Bool {
        if let x = Int(a), let y = Int(b) { return x == y }
        return a == b
    }
}

/// SAX-style parser for the small XML schema shared by the DB Timetables `plan`/`fchg`/`rchg`
/// endpoints: a `<timetable>` of `<s id="...">` stops, each with an optional `<tl>` (trip label:
/// category `c`, number `n`) and optional `<ar>`/`<dp>` (arrival/departure: planned time `pt`,
/// changed time `ct`, planned/changed platform `pp`/`cp`, changed status `cs` — "c" means cancelled).
enum TimetablesXMLParser {
    static func parse(_ data: Data) -> [TimetablesStop] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.stops
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var stops: [TimetablesStop] = []
        private var id: String?
        private var category: String?
        private var number: String?
        private var arrival: TimetablesEvent?
        private var departure: TimetablesEvent?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch elementName {
            case "s":
                id = attributes["id"]; category = nil; number = nil; arrival = nil; departure = nil
            case "tl":
                category = attributes["c"]
                number = attributes["n"]
            case "ar":
                arrival = Self.event(from: attributes)
            case "dp":
                departure = Self.event(from: attributes)
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard elementName == "s", let id, arrival != nil || departure != nil else { return }
            stops.append(TimetablesStop(id: id, category: category, number: number, arrival: arrival, departure: departure))
        }

        private static func event(from attributes: [String: String]) -> TimetablesEvent? {
            let planned = attributes["pt"].flatMap(parseTime)
            let actual = attributes["ct"].flatMap(parseTime)
            guard planned != nil || actual != nil else { return nil }
            return TimetablesEvent(planned: planned, actual: actual, plannedPlatform: attributes["pp"],
                                    actualPlatform: attributes["cp"], cancelled: attributes["cs"] == "c")
        }

        /// "YYMMDDHHmm" in German local time.
        private static func parseTime(_ string: String) -> Date? {
            guard string.count == 10, string.allSatisfy(\.isNumber) else { return nil }
            let digits = Array(string)
            func pair(_ index: Int) -> Int? { Int(String(digits[index...index + 1])) }
            guard let yy = pair(0), let mm = pair(2), let dd = pair(4), let hh = pair(6), let min = pair(8) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimetablesClient.berlin
            var components = DateComponents()
            components.year = 2000 + yy
            components.month = mm
            components.day = dd
            components.hour = hh
            components.minute = min
            return calendar.date(from: components)
        }
    }
}
