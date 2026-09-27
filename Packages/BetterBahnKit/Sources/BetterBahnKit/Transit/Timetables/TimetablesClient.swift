import Foundation

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

/// One `<ar>`/`<dp>` (arrival/departure) side of a stop, from either a `plan` response (planned
/// time/platform) or a `fchg` response (actual time/platform, cancellation).
struct TimetablesEvent {
    var planned: Date?
    var actual: Date?
    var plannedPlatform: String?
    var actualPlatform: String?
    var cancelled: Bool
    /// The stop's `<m>` messages from `fchg` (filled in by `liveEvent`; `plan` never has any).
    var messages: [TimetablesMessage] = []
}

/// One `<m>` element from `fchg`: a numeric delay-reason or quality code, reported at `timestamp`.
struct TimetablesMessage: Hashable {
    var code: Int
    var timestamp: Date?

    /// Readable messages for `raw`, collected from any number of stops: unknown codes are dropped,
    /// and "all clear" codes (e.g. "keine Qualitätsmängel") remove the older notices they resolve.
    static func resolve(_ raw: [TimetablesMessage]) -> [TrainMessage] {
        let shown = raw.filter { message in
            guard TrainMessageCodes.clearing[message.code] == nil else { return false }
            return !raw.contains { clearing in
                TrainMessageCodes.clearing[clearing.code]?.contains(message.code) == true
                    && (clearing.timestamp ?? .distantPast) > (message.timestamp ?? .distantPast)
            }
        }
        return TrainMessage.merged(shown.compactMap { message in
            guard let text = TrainMessageCodes.text(for: message.code) else { return nil }
            let isDelay = message.code < 70 || message.code == 99
            return TrainMessage(kind: isDelay ? .delay : .notice, text: text, timestamp: message.timestamp)
        })
    }
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
    var messages: [TimetablesMessage] = []
}

/// Overlay to apply onto a `Leg` once a matching `TimetablesStop` was found.
public struct TimetablesLegOverride: Sendable {
    public var departure: TimeInfo?
    public var departurePlatform: PlatformInfo?
    public var arrival: TimeInfo?
    public var arrivalPlatform: PlatformInfo?
    /// `true` when DB reports either end cancelled, `false` when DB matched both ends and both run,
    /// `nil` when DB only knows one end (the other provider's verdict should then stand).
    public var cancelled: Bool?
    /// Delay reasons and notices DB reports for the train at either end.
    public var messages: [TrainMessage] = []
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

    /// Shared by every `TimetablesClient` (the app makes a fresh one per use), so the journey
    /// refresh and the trip views reuse each other's responses instead of hitting the API again.
    /// Concurrent requests for the same path are merged into one.
    private actor Cache {
        struct Entry { let date: Date; let stops: [TimetablesStop] }
        var entries: [String: Entry] = [:]
        var inFlight: [String: Task<[TimetablesStop], Error>] = [:]

        func stops(for path: String, maxAge: TimeInterval,
                   fetch: @escaping @Sendable () async throws -> [TimetablesStop]) async throws -> [TimetablesStop] {
            if let entry = entries[path], Date.now.timeIntervalSince(entry.date) < maxAge { return entry.stops }
            if let task = inFlight[path] { return try await task.value }
            let task = Task { try await fetch() }
            inFlight[path] = task
            defer { inFlight[path] = nil }
            let stops = try await task.value
            entries[path] = Entry(date: .now, stops: stops)
            return stops
        }

        func clear(prefix: String) {
            entries = entries.filter { !$0.key.hasPrefix(prefix) }
        }
    }
    private static let cache = Cache()
    /// The schedule (`plan`) barely changes; live changes (`fchg`) are re-fetched at most this often.
    static let planMaxAge: TimeInterval = 30 * 60
    static let changesMaxAge: TimeInterval = 4 * 60

    /// Drops cached delays so the next lookup asks DB again (e.g. on pull-to-refresh).
    public static func invalidateDelays() async {
        await cache.clear(prefix: "fchg/")
    }

    private func get(path: String, maxAge: TimeInterval) async throws -> [TimetablesStop] {
        // Only the app's real session shares the cache; a client on a custom session (tests, mocks)
        // must never see another client's stored responses for the same path.
        guard http.session === URLSession.shared else { return try await fetch(path: path) }
        return try await Self.cache.stops(for: path, maxAge: maxAge) { try await self.fetch(path: path) }
    }

    private func fetch(path: String) async throws -> [TimetablesStop] {
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
        return try await get(path: "plan/\(eva)/\(date)/\(hour)", maxAge: Self.planMaxAge)
    }

    /// Every currently known change (delay, platform swap, cancellation) at `eva`, keyed by stop id.
    private func changes(eva: String) async throws -> [String: TimetablesStop] {
        let stops = try await get(path: "fchg/\(eva)", maxAge: Self.changesMaxAge)
        return Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func eva(for station: Station) async -> String? {
        if let eva = station.evaNumber { return eva }
        return try? await bahnDe.evaNumber(for: station)
    }

    /// The event for `category`+`number` at `eva`, on whichever `side` (arrival or departure) has a
    /// planned time within `matchTolerance` of `time`. Starts from the scheduled `plan` entry (which
    /// always carries the planned platform, even when nothing has changed) and overlays whatever
    /// `fchg` (Gleisänderungen, delays, cancellations) currently reports for that same stop.
    private func liveEvent(eva: String, category: String, number: String, time: Date,
                            side: KeyPath<TimetablesStop, TimetablesEvent?>) async -> TimetablesEvent? {
        guard let planned = try? await plan(eva: eva, around: time),
              let stop = Self.match(planned, category: category, number: number, plannedTime: time, side: side) else { return nil }
        // Without `fchg` there's no telling whether the train is late or even cancelled – treating
        // the bare schedule as "on time, running" would wipe out what the other provider knows.
        guard let changes = try? await changes(eva: eva) else { return nil }
        var event = stop[keyPath: side]
        if let changed = changes[stop.id] {
            if let change = changed[keyPath: side] {
                if let actual = change.actual { event?.actual = actual }
                if let actualPlatform = change.actualPlatform { event?.actualPlatform = actualPlatform }
                event?.cancelled = change.cancelled
            }
            event?.messages = changed.messages
        }
        return event
    }

    /// Whether DB's own dispatching feed reports the departure of `category`+`number` at `station`
    /// (planned `time`) as cancelled. `nil` when it can't tell (no credentials, train not found, or
    /// the request failed), so callers can keep trusting whatever another provider said.
    public func departureCancelled(category: String, number: String, at station: Station, plannedTime: Date) async -> Bool? {
        guard credentials.isConfigured, let eva = await eva(for: station),
              let event = await liveEvent(eva: eva, category: category, number: number, time: plannedTime, side: \.departure)
        else { return nil }
        return event.cancelled
    }

    /// Whether `realtime(for:)` can even try to look `leg` up (credentials set, a train with a
    /// category and number).
    public func canLookUp(_ leg: Leg) -> Bool {
        credentials.isConfigured && !leg.isWalking && leg.line?.dispatchNumber != nil
            && leg.line.flatMap { Self.category(from: $0.name) } != nil
    }

    /// Live data for `leg`'s departure and arrival, matched by category, train number and planned
    /// time. Returns `nil` when nothing changed is known yet at either station, so callers should
    /// keep whatever schedule they already have.
    public func realtime(for leg: Leg) async -> TimetablesLegOverride? {
        guard credentials.isConfigured, !leg.isWalking, let line = leg.line, let number = line.dispatchNumber,
              let category = Self.category(from: line.name) else { return nil }

        var departure: TimeInfo?
        var departurePlatform: PlatformInfo?
        var arrival: TimeInfo?
        var arrivalPlatform: PlatformInfo?
        var departureCancelled: Bool?
        var arrivalCancelled: Bool?
        var messages: [TimetablesMessage] = []

        if let eva = await eva(for: leg.origin),
           let event = await liveEvent(eva: eva, category: category, number: number, time: leg.departure.planned, side: \.departure) {
            // DB lists only changes: a matched stop without one is live and on time.
            departure = TimeInfo(planned: leg.departure.planned, actual: event.actual ?? leg.departure.actual ?? leg.departure.planned)
            departurePlatform = Self.mergedPlatform(existing: leg.departurePlatform, event: event)
            departureCancelled = event.cancelled
            messages += event.messages
        }

        if let eva = await eva(for: leg.destination),
           let event = await liveEvent(eva: eva, category: category, number: number, time: leg.arrival.planned, side: \.arrival) {
            arrival = TimeInfo(planned: leg.arrival.planned, actual: event.actual ?? leg.arrival.actual ?? leg.arrival.planned)
            arrivalPlatform = Self.mergedPlatform(existing: leg.arrivalPlatform, event: event)
            arrivalCancelled = event.cancelled
            messages += event.messages
        }

        guard departure != nil || arrival != nil else { return nil }
        let cancelled: Bool? = if departureCancelled == true || arrivalCancelled == true {
            true
        } else if departureCancelled == false, arrivalCancelled == false {
            false
        } else {
            nil
        }
        return TimetablesLegOverride(departure: departure, departurePlatform: departurePlatform,
                                      arrival: arrival, arrivalPlatform: arrivalPlatform, cancelled: cancelled,
                                      messages: TimetablesMessage.resolve(messages))
    }

    /// `leg`'s stopovers with DB Timetables' delays laid over them: where DB knows a stop its data wins
    /// (unchanged means on time, not cancelled), and a stop DB can't match keeps whatever it already had.
    public func stopoversWithRealtime(for leg: Leg) async -> [Stopover] {
        await liveStopovers(for: leg).stopovers
    }

    /// `stopoversWithRealtime(for:)` plus every delay reason and notice DB reports at any of those
    /// stops — what DB Navigator lists under "Aktuelle Informationen" for this part of the ride.
    public func liveStopovers(for leg: Leg) async -> (stopovers: [Stopover], messages: [TrainMessage]) {
        guard canLookUp(leg), let line = leg.line else { return (leg.stopovers, []) }
        let (stopovers, messages) = await stopoversWithRealtime(leg.stopovers, line: line)
        return (stopovers, TimetablesMessage.resolve(messages))
    }

    /// `trip` with DB Timetables delays laid over it (see `stopoversWithRealtime(for:)`);
    /// returned unchanged when there are no credentials or the train has no category/number.
    public func tripWithRealtime(_ trip: Trip) async -> Trip {
        guard credentials.isConfigured, let line = trip.line else { return trip }
        var trip = trip
        let (stopovers, messages) = await stopoversWithRealtime(trip.stopovers, line: line)
        trip.stopovers = stopovers
        trip.messages = TrainMessage.merged(trip.messages + TimetablesMessage.resolve(messages))
        return trip
    }

    private func stopoversWithRealtime(_ original: [Stopover], line: Line) async -> ([Stopover], [TimetablesMessage]) {
        guard let number = line.dispatchNumber, let category = Self.category(from: line.name) else { return (original, []) }
        var stops = original
        var messages: [TimetablesMessage] = []
        await withTaskGroup(of: (Int, TimetablesEvent?, TimetablesEvent?).self) { group in
            for index in stops.indices {
                let stop = stops[index]
                group.addTask {
                    guard let eva = await self.eva(for: stop.station) else { return (index, nil, nil) }
                    var arrival: TimetablesEvent?
                    var departure: TimetablesEvent?
                    if let time = stop.arrival?.planned {
                        arrival = await self.liveEvent(eva: eva, category: category, number: number, time: time, side: \.arrival)
                    }
                    if let time = stop.departure?.planned {
                        departure = await self.liveEvent(eva: eva, category: category, number: number, time: time, side: \.departure)
                    }
                    return (index, arrival, departure)
                }
            }
            for await (index, arrival, departure) in group {
                messages += (arrival?.messages ?? []) + (departure?.messages ?? [])
                if let arrival {
                    let known = stops[index].arrival
                    stops[index].arrival?.actual = arrival.actual ?? known?.actual ?? known?.planned
                    // DB wins here too, both ways: Transitous' realtime feed only knows whole skipped
                    // stops and has been seen flagging stops DB runs normally (RE 3318 Wittenberg–Zahna).
                    stops[index].arrivalCancelled = arrival.cancelled
                }
                if let departure {
                    let known = stops[index].departure
                    stops[index].departure?.actual = departure.actual ?? known?.actual ?? known?.planned
                    stops[index].departureCancelled = departure.cancelled
                }
            }
        }
        return (stops, messages)
    }

    /// Combines whatever platform a caller already had with a DB Timetables `event`: a genuine
    /// Gleisänderung (`event.actualPlatform`, from `fchg`) always wins and is overlaid onto the
    /// existing planned platform; otherwise, only when nothing was known at all, DB's own scheduled
    /// platform (`event.plannedPlatform`, from `plan`) fills the gap rather than showing nothing.
    private static func mergedPlatform(existing: PlatformInfo?, event: TimetablesEvent) -> PlatformInfo? {
        if let actualPlatform = event.actualPlatform {
            return PlatformInfo(planned: existing?.planned, actual: actualPlatform)
        } else if existing?.best == nil, let plannedPlatform = event.plannedPlatform {
            return PlatformInfo(planned: plannedPlatform, actual: nil)
        }
        return nil
    }

    /// Fills in a missing platform for any of `trip`'s stopovers – in practice mainly the trip's own
    /// first and last stop: Transitous' `v5/trip` response reliably carries a platform for
    /// `intermediateStops` but sometimes omits it for the leg's own `from`/`to` place (reported for
    /// the S15 at Berlin Hbf/Berlin Gesundbrunnen, which DB Navigator shows correctly) – using DB's
    /// own Timetables ("IRIS") schedule. Only queried for stopovers that are actually missing a
    /// platform, so a long route doesn't fire a lookup per stop; a stopover that already has one is
    /// left untouched (see `realtime(for:)` for overlaying live Gleisänderungen onto an existing leg).
    public func fillMissingPlatforms(in trip: Trip) async -> Trip {
        guard credentials.isConfigured, let line = trip.line, let number = line.dispatchNumber,
              let category = Self.category(from: line.name) else { return trip }
        var trip = trip
        await withTaskGroup(of: (Int, PlatformInfo?, PlatformInfo?).self) { group in
            for index in trip.stopovers.indices {
                let stop = trip.stopovers[index]
                let needsArrival = stop.arrival != nil && stop.arrivalPlatform?.best == nil
                let needsDeparture = stop.departure != nil && stop.departurePlatform?.best == nil
                guard needsArrival || needsDeparture else { continue }
                group.addTask {
                    guard let eva = await self.eva(for: stop.station) else { return (index, nil, nil) }
                    var arrivalPlatform: PlatformInfo?
                    var departurePlatform: PlatformInfo?
                    if needsArrival, let time = stop.arrival?.planned,
                       let event = await self.liveEvent(eva: eva, category: category, number: number, time: time, side: \.arrival) {
                        arrivalPlatform = Self.mergedPlatform(existing: stop.arrivalPlatform, event: event)
                    }
                    if needsDeparture, let time = stop.departure?.planned,
                       let event = await self.liveEvent(eva: eva, category: category, number: number, time: time, side: \.departure) {
                        departurePlatform = Self.mergedPlatform(existing: stop.departurePlatform, event: event)
                    }
                    return (index, arrivalPlatform, departurePlatform)
                }
            }
            for await (index, arrivalPlatform, departurePlatform) in group {
                if let arrivalPlatform { trip.stopovers[index].arrivalPlatform = arrivalPlatform }
                if let departurePlatform { trip.stopovers[index].departurePlatform = departurePlatform }
            }
        }
        return trip
    }

    /// Fills in a missing platform for any of `entries` – e.g. reported for Berlin Gesundbrunnen,
    /// where Transitous carries a platform for U-Bahn departures but not for the S-Bahn ones at the
    /// very same board, apparently a gap in S-Bahn Berlin's own feed rather than anything DB Navigator
    /// hits – using DB's own Timetables ("IRIS") schedule. Only queried for entries actually missing a
    /// platform, and only one `eva` lookup for the whole board since every entry shares `station`.
    public func fillMissingPlatforms(in entries: [BoardEntry], at station: Station) async -> [BoardEntry] {
        guard credentials.isConfigured, let eva = await eva(for: station) else { return entries }
        var entries = entries
        await withTaskGroup(of: (Int, PlatformInfo?).self) { group in
            for index in entries.indices {
                let entry = entries[index]
                guard entry.platform.best == nil, let number = entry.line.dispatchNumber,
                      let category = Self.category(from: entry.line.name) else { continue }
                group.addTask {
                    let event = entry.kind == .arrivals
                        ? await self.liveEvent(eva: eva, category: category, number: number, time: entry.time.planned, side: \.arrival)
                        : await self.liveEvent(eva: eva, category: category, number: number, time: entry.time.planned, side: \.departure)
                    guard let event else { return (index, nil) }
                    return (index, Self.mergedPlatform(existing: entry.platform, event: event))
                }
            }
            for await (index, platform) in group {
                if let platform { entries[index].platform = platform }
            }
        }
        return entries
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

    /// "ICE 571" -> "ICE". Also handles names with no space between category and number ("S15" -> "S",
    /// as Transitous names S-Bahn lines) by taking the leading non-digit run of the first token, since
    /// IRIS always splits them into a separate category (`tl`'s `c`) and number (`n`).
    static func category(from lineName: String) -> String? {
        guard let first = lineName.split(separator: " ").first else { return nil }
        let letters = first.prefix(while: { !$0.isNumber })
        return letters.isEmpty ? nil : letters.uppercased()
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
/// `fchg` also nests `<m>` messages (type `t`, code `c`, timestamp `ts`, deleted `del`) in a stop and
/// its `<ar>`/`<dp>`; the delay-reason (`t="d"`) and quality (`t="q"`) ones are collected per stop.
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
        private var messages: [TimetablesMessage] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch elementName {
            case "s":
                id = attributes["id"]; category = nil; number = nil; arrival = nil; departure = nil; messages = []
            case "tl":
                category = attributes["c"]
                number = attributes["n"]
            case "ar":
                arrival = Self.event(from: attributes)
            case "dp":
                departure = Self.event(from: attributes)
            case "m":
                guard id != nil, attributes["t"] == "d" || attributes["t"] == "q", attributes["del"] != "1",
                      let code = attributes["c"].flatMap({ Int($0) }) else { break }
                messages.append(TimetablesMessage(code: code, timestamp: attributes["ts"].flatMap { Self.parseTime(String($0.prefix(10))) }))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard elementName == "s", let id else { return }
            // Keep the id around until here: `<m>` elements only count while inside a stop.
            defer { self.id = nil }
            guard arrival != nil || departure != nil || !messages.isEmpty else { return }
            stops.append(TimetablesStop(id: id, category: category, number: number, arrival: arrival,
                                        departure: departure, messages: messages))
        }

        private static func event(from attributes: [String: String]) -> TimetablesEvent? {
            let planned = attributes["pt"].flatMap(parseTime)
            let actual = attributes["ct"].flatMap(parseTime)
            let cancelled = attributes["cs"] == "c"
            // `fchg` reports a cancellation as just `cs="c" clt="…"` (no `pt`/`ct`), so the status
            // alone must still make an event — otherwise every DB cancellation got dropped here.
            guard planned != nil || actual != nil || cancelled else { return nil }
            return TimetablesEvent(planned: planned, actual: actual, plannedPlatform: attributes["pp"],
                                    actualPlatform: attributes["cp"], cancelled: cancelled)
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
