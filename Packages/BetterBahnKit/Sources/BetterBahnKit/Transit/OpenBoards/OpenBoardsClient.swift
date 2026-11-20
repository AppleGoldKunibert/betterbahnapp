import Foundation

/// Which board an entry comes from: where a train arrives at a station or where it departs.
enum BoardSide: Sendable {
    case arrival, departure
}

/// One arrival or departure of a train at a station, from a DB OpenBoards board: the planned and the
/// live time and platform, and whether DB cancelled the stop.
struct OpenBoardsEvent: Sendable {
    var planned: Date?
    /// The live time, only when DB reports one: a delay or early time, or a time already run. A forecast
    /// equal to the schedule stays `nil`, so it reads as "no change" (see `OpenBoardsClient.infersOnTime`).
    var actual: Date?
    var plannedPlatform: String?
    /// The platform DB now says, only when it differs from the planned one (a Gleisänderung).
    var actualPlatform: String?
    var cancelled: Bool
    /// The delay reasons and notices (DB's RIS codes) the board lists for this stop.
    var messages: [OpenBoardsMessage] = []
}

/// A delay-reason or quality code (RIS cause code / quality deviation) a board lists for a stop.
struct OpenBoardsMessage: Hashable, Sendable {
    var code: Int
    var timestamp: Date?

    /// Readable messages for `raw`, collected from any number of stops: unknown codes are dropped,
    /// and "all clear" codes (e.g. "keine Qualitätsmängel") remove the older notices they resolve.
    static func resolve(_ raw: [OpenBoardsMessage]) -> [TrainMessage] {
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

/// One entry of a board: a train's stop with its category, number and `event`.
struct OpenBoardsEntry: Sendable {
    /// The external category ("ICE", "RE", "S") and DB's internal one. For private operators the
    /// category can be the operator's code instead of what the line says (National Express's RE1).
    var category: String?
    var categoryInternal: String?
    var number: String?
    /// The line as passengers see it (e.g. "RE1").
    var lineName: String?
    var event: OpenBoardsEvent

    /// Whether `category` (as taken from another provider's line name, e.g. "RE") names this train,
    /// either as DB's own category or as the letters of its line name.
    func isCategory(_ category: String) -> Bool {
        let category = category.uppercased()
        return self.category?.uppercased() == category
            || categoryInternal?.uppercased() == category
            || lineName.flatMap(OpenBoardsClient.category(from:)) == category
    }
}

/// Overlay to apply onto a `Leg` once a matching `OpenBoardsEntry` was found.
public struct OpenBoardsLegOverride: Sendable {
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
/// feed (the "OpenBoards" API of the DB API Marketplace, which replaces Timetables), since Transitous'
/// realtime coverage for DB long-distance trains can lag by many minutes or be missing entirely. This
/// API has no journey search of its own: it lists the departures or arrivals of a station in a time
/// window, each with its schedule and live time and platform. So every lookup asks the board of the
/// train's station around its planned time and finds the train in it (by category, train number and
/// planned time). Used to overlay onto legs that already came from another provider, not as a
/// replacement for routing.
public struct OpenBoardsClient: Sendable {
    /// DB's OpenBoards API through the `Cloudflare/bahnde-proxy` Worker, which adds the API key (a Worker
    /// secret, never in the app), builds DB's POST from this GET and only answers the genuine app (`WorkerAuth`).
    public static let baseURL = URL(string: "https://betterbahn2.betterbahn.workers.dev/openboards/v1")!
    /// A stop only counts as a match when its planned time is this close to the leg's.
    static let matchTolerance: TimeInterval = 180
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    let http: HTTPClient
    let bahnDe: BahnDeClient
    let auth: WorkerAuth?

    /// `auth` defaults to `WorkerAuth.shared` on the app's real session and none on others (tests).
    public init(http: HTTPClient = HTTPClient(timeout: 6), bahnDe: BahnDeClient = BahnDeClient(), auth: WorkerAuth? = nil) {
        self.http = http
        self.bahnDe = bahnDe
        self.auth = http.workerAuth(auth)
    }

    /// Shared by every `OpenBoardsClient` (the app makes a fresh one per use), so the journey
    /// refresh and the trip views reuse each other's responses instead of hitting the API again.
    /// Concurrent requests for the same board are merged into one.
    private actor Cache<Value: Sendable> {
        struct Entry { let date: Date; let value: Value }
        var entries: [String: Entry] = [:]
        var inFlight: [String: Task<Value, Error>] = [:]

        func value(for path: String, maxAge: TimeInterval,
                   fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
            if let entry = entries[path], Date.now.timeIntervalSince(entry.date) < maxAge { return entry.value }
            if let task = inFlight[path] { return try await task.value }
            let task = Task { try await fetch() }
            inFlight[path] = task
            defer { inFlight[path] = nil }
            let value = try await task.value
            entries[path] = Entry(date: .now, value: value)
            return value
        }

        func clear() {
            entries = [:]
        }
    }
    private static let cache = Cache<[OpenBoardsEntry]>()
    /// A board carries the schedule and the live changes together, so it is re-fetched at most this often.
    static let boardMaxAge: TimeInterval = 4 * 60

    /// A board is asked for a window that starts a little before the half hour holding the time looked
    /// up and reaches well past it, so a train that runs early or late is still in it. The window only
    /// depends on that half hour, so every lookup in it (a whole station board, the stops of a journey)
    /// shares one request. Kept short, as a board lists at most 50 trains per product class.
    static let slot: TimeInterval = 30 * 60
    static let lookBehind: TimeInterval = 10 * 60
    static let lookAhead: TimeInterval = 50 * 60

    static func window(around time: Date) -> (start: Date, end: Date) {
        let slotStart = (time.timeIntervalSince1970 / slot).rounded(.down) * slot
        return (Date(timeIntervalSince1970: slotStart - lookBehind), Date(timeIntervalSince1970: slotStart + slot + lookAhead))
    }

    /// DB's change list drops a train a few hours after it ran (#76's S7 was still there
    /// 4 hours after arriving, gone after 6). Later DB only finds the schedule and would call the
    /// train on time, a made-up "+0", so a train whose last stop is longer ago isn't asked about.
    static let changesMemory: TimeInterval = 4 * 3600

    static func knowsChanges(until lastPlanned: Date, now: Date) -> Bool {
        lastPlanned.addingTimeInterval(changesMemory) > now
    }

    /// DB only has live times for a train about to run: hours ahead (a journey tomorrow) nothing is live
    /// yet, and an inferred "pünktlich"/"+0" would be made up. Then only a change DB actually reports shows.
    static let onTimeLookahead: TimeInterval = 2 * 3600

    static func infersOnTime(departing start: Date, now: Date) -> Bool {
        start.timeIntervalSince(now) < onTimeLookahead
    }

    /// Drops cached boards so the next lookup asks DB again (e.g. on pull-to-refresh).
    public static func invalidateDelays() async {
        await cache.clear()
    }

    /// The `side` board for `evas` between `start` and `end`.
    private func board(_ side: BoardSide, evas: [String], from start: Date, to end: Date) async throws -> [OpenBoardsEntry] {
        let name = side == .arrival ? "arrivals" : "departures"
        let url = Self.baseURL.appending(path: name).appending(queryItems: [
            URLQueryItem(name: "evas", value: evas.joined(separator: ",")),
            URLQueryItem(name: "from", value: JSONDecoding.isoString(start)),
            URLQueryItem(name: "to", value: JSONDecoding.isoString(end)),
        ])
        // Only the app's real session shares the cache; a client on a custom session (tests, mocks)
        // must never see another client's stored responses for the same board.
        guard http.session === URLSession.shared else { return try await fetch(url, side: side) }
        return try await Self.cache.value(for: url.absoluteString, maxAge: Self.boardMaxAge) { try await self.fetch(url, side: side) }
    }

    private func fetch(_ url: URL, side: BoardSide) async throws -> [OpenBoardsEntry] {
        var request = URLRequest(url: url, timeoutInterval: http.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try OpenBoardsParser.parse(try await http.sendRaw(request, auth: auth), side: side)
    }

    /// The board around `time` at `eva` and its lower levels (see `lowerLevels`).
    private func board(_ side: BoardSide, eva: String, around time: Date) async throws -> [OpenBoardsEntry] {
        let window = Self.window(around: time)
        return try await board(side, evas: [eva] + (Self.lowerLevels[eva] ?? []), from: window.start, to: window.end)
    }

    /// A station with several levels (Leipzig Hbf, Berlin Südkreuz) has no single EVA number in the offline list;
    /// its main one will do here, since a board also lists the station's other levels. Before, such a stop needed
    /// bahn.de's station search on every refresh and lost DB's delays whenever bahn.de didn't answer (#411).
    private func eva(for station: Station) async -> String? {
        if let eva = station.evaNumber { return eva }
        if let eva = StationNames.mainEvaNumber(for: station) { return eva }
        return try? await bahnDe.evaNumber(for: station)
    }

    /// The event for `category`+`number` at `eva` on `side`, from the board around `time`, with its planned and
    /// live time and platform. `nil` when the train isn't on the board or the board can't be had: treating
    /// the bare schedule as "on time, running" would wipe out what the other provider knows.
    private func liveEvent(eva: String, category: String, number: String, time: Date,
                            side: BoardSide) async -> OpenBoardsEvent? {
        guard let entries = try? await board(side, eva: eva, around: time) else { return nil }
        return Self.match(entries, category: category, number: number, plannedTime: time)?.event
    }

    /// Big stations whose S-Bahn platforms DB lists as a station of their own, which station search (and so
    /// `eva(for:)`) never returns. A board is asked for them together with the main one: without them an S-Bahn
    /// ending there got no DB delay at all and kept Transitous' forecast, which often drops back to "on time" for
    /// stops further ahead (issue #76: S4 running 3 minutes late, its arrival shown on time).
    static let lowerLevels: [String: [String]] = [
        "8000261": ["8098263"], // München Hbf (tief)
        "8000096": ["8098096"], // Stuttgart Hbf (tief)
        "8000105": ["8098105"], // Frankfurt (Main) Hbf (tief)
        "8002549": ["8098549"], // Hamburg Hbf (S-Bahn)
        "8010205": ["8098205"], // Leipzig Hbf (tief)
        "8011160": ["8098160", "8089021"], // Berlin Hbf (tief), Berlin Hbf (S-Bahn)
    ]

    /// Whether DB's own dispatching feed reports the departure of `category`+`number` at `station`
    /// (planned `time`) as cancelled. `nil` when it can't tell (train not found, or
    /// the request failed), so callers can keep trusting whatever another provider said.
    public func departureCancelled(category: String, number: String, at station: Station, plannedTime: Date) async -> Bool? {
        guard let eva = await eva(for: station),
              let event = await liveEvent(eva: eva, category: category, number: number, time: plannedTime, side: .departure)
        else { return nil }
        return event.cancelled
    }

    /// Whether `realtime(for:)` can even try to look `leg` up (a train with a
    /// category and number).
    public func canLookUp(_ leg: Leg) -> Bool {
        !leg.isWalking && canLookUp(leg.line)
    }

    /// Whether `line` is a train DB's boards can be asked about (one with a category and number).
    public func canLookUp(_ line: Line?) -> Bool {
        line?.dispatchNumber != nil && line.flatMap { Self.category(from: $0.name) } != nil
    }

    /// Live data for `leg`'s departure and arrival, matched by category, train number and planned
    /// time. Returns `nil` when nothing is known yet at either station, so callers should
    /// keep whatever schedule they already have.
    public func realtime(for leg: Leg, now: Date = .now) async -> OpenBoardsLegOverride? {
        guard !leg.isWalking, let line = leg.line, let number = line.dispatchNumber,
              let category = Self.category(from: line.name) else { return nil }

        var departure: TimeInfo?
        var departurePlatform: PlatformInfo?
        var arrival: TimeInfo?
        var arrivalPlatform: PlatformInfo?
        var departureCancelled: Bool?
        var arrivalCancelled: Bool?
        var messages: [OpenBoardsMessage] = []
        let onTime = Self.infersOnTime(departing: leg.departure.planned, now: now)

        if let eva = await eva(for: leg.origin),
           let event = await liveEvent(eva: eva, category: category, number: number, time: leg.departure.planned, side: .departure) {
            // A matched stop without a live time is on time (`infersOnTime`).
            departure = TimeInfo(planned: leg.departure.planned,
                                 actual: event.actual ?? leg.departure.actual ?? (onTime ? leg.departure.planned : nil))
            departurePlatform = Self.mergedPlatform(existing: leg.departurePlatform, event: event)
            departureCancelled = event.cancelled
            messages += event.messages
        }

        if let eva = await eva(for: leg.destination),
           let event = await liveEvent(eva: eva, category: category, number: number, time: leg.arrival.planned, side: .arrival) {
            arrival = TimeInfo(planned: leg.arrival.planned,
                               actual: event.actual ?? leg.arrival.actual ?? (onTime ? leg.arrival.planned : nil))
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
        return OpenBoardsLegOverride(departure: departure, departurePlatform: departurePlatform,
                                      arrival: arrival, arrivalPlatform: arrivalPlatform, cancelled: cancelled,
                                      messages: OpenBoardsMessage.resolve(messages))
    }

    /// `leg`'s stopovers with DB OpenBoards' delays laid over them: where DB knows a stop its data wins
    /// (unchanged means on time once the train is about to run, see `infersOnTime`; not cancelled), and a
    /// stop DB can't match keeps whatever it already had.
    public func stopoversWithRealtime(for leg: Leg, now: Date = .now) async -> [Stopover] {
        await liveStopovers(for: leg, now: now).stopovers
    }

    /// `stopoversWithRealtime(for:)` plus every delay reason and notice DB reports at any of those
    /// stops — what DB Navigator lists under "Aktuelle Informationen" for this part of the ride.
    public func liveStopovers(for leg: Leg, now: Date = .now) async -> (stopovers: [Stopover], messages: [TrainMessage]) {
        guard canLookUp(leg), let line = leg.line else { return (leg.stopovers, []) }
        let (stopovers, messages) = await stopoversWithRealtime(leg.stopovers, line: line, now: now)
        return (stopovers, OpenBoardsMessage.resolve(messages))
    }

    /// `trip` with DB OpenBoards delays laid over it (see `stopoversWithRealtime(for:)`);
    /// returned unchanged when the train has no category/number or ran too long ago (`changesMemory`).
    public func tripWithRealtime(_ trip: Trip, now: Date = .now) async -> Trip {
        guard let line = trip.line else { return trip }
        if let last = trip.stopovers.last.flatMap({ $0.arrival?.planned ?? $0.departure?.planned }),
           !Self.knowsChanges(until: last, now: now) { return trip }
        var trip = trip
        let (stopovers, messages) = await stopoversWithRealtime(trip.stopovers, line: line, now: now)
        trip.stopovers = stopovers
        trip.messages = TrainMessage.merged(trip.messages + OpenBoardsMessage.resolve(messages))
        return trip
    }

    private func stopoversWithRealtime(_ original: [Stopover], line: Line, now: Date) async -> ([Stopover], [OpenBoardsMessage]) {
        guard let number = line.dispatchNumber, let category = Self.category(from: line.name) else { return (original, []) }
        var stops = original
        // Judged once for the whole run, so every stop agrees: before, a train tomorrow showed "+0"
        // at the stops whose schedule DB already had and plain times further on.
        let onTime = original.first.flatMap { $0.departure?.planned ?? $0.arrival?.planned }
            .map { Self.infersOnTime(departing: $0, now: now) } ?? false
        var messages: [OpenBoardsMessage] = []
        await withTaskGroup(of: (Int, OpenBoardsEvent?, OpenBoardsEvent?).self) { group in
            for index in stops.indices {
                let stop = stops[index]
                group.addTask {
                    guard let eva = await self.eva(for: stop.station) else { return (index, nil, nil) }
                    var arrival: OpenBoardsEvent?
                    var departure: OpenBoardsEvent?
                    if let time = stop.arrival?.planned {
                        arrival = await self.liveEvent(eva: eva, category: category, number: number, time: time, side: .arrival)
                    }
                    if let time = stop.departure?.planned {
                        departure = await self.liveEvent(eva: eva, category: category, number: number, time: time, side: .departure)
                    }
                    return (index, arrival, departure)
                }
            }
            for await (index, arrival, departure) in group {
                messages += (arrival?.messages ?? []) + (departure?.messages ?? [])
                if let arrival {
                    let known = stops[index].arrival
                    stops[index].arrival?.actual = arrival.actual ?? known?.actual ?? (onTime ? known?.planned : nil)
                    // DB wins here too, both ways: Transitous' realtime feed only knows whole skipped
                    // stops and has been seen flagging stops DB runs normally (RE 3318 Wittenberg–Zahna).
                    stops[index].arrivalCancelled = arrival.cancelled
                }
                if let departure {
                    let known = stops[index].departure
                    stops[index].departure?.actual = departure.actual ?? known?.actual ?? (onTime ? known?.planned : nil)
                    stops[index].departureCancelled = departure.cancelled
                }
            }
        }
        return (stops, messages)
    }

    /// Combines whatever platform a caller already had with a DB OpenBoards `event`: a genuine
    /// Gleisänderung (`event.actualPlatform`) always wins and is overlaid onto the
    /// existing planned platform; otherwise, only when nothing was known at all, DB's own scheduled
    /// platform (`event.plannedPlatform`) fills the gap rather than showing nothing.
    private static func mergedPlatform(existing: PlatformInfo?, event: OpenBoardsEvent) -> PlatformInfo? {
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
    /// own boards. Only queried for stopovers that are actually missing a
    /// platform, so a long route doesn't fire a lookup per stop; a stopover that already has one is
    /// left untouched (see `realtime(for:)` for overlaying live Gleisänderungen onto an existing leg).
    /// `trip` with DB's delays (`tripWithRealtime(_:)`) and missing platforms (`fillMissingPlatforms(in:)`).
    public func liveTrip(_ trip: Trip, now: Date = .now) async -> Trip {
        await fillMissingPlatforms(in: await tripWithRealtime(trip, now: now))
    }

    public func fillMissingPlatforms(in trip: Trip) async -> Trip {
        guard let line = trip.line, let number = line.dispatchNumber,
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
                       let event = await self.liveEvent(eva: eva, category: category, number: number, time: time, side: .arrival) {
                        arrivalPlatform = Self.mergedPlatform(existing: stop.arrivalPlatform, event: event)
                    }
                    if needsDeparture, let time = stop.departure?.planned,
                       let event = await self.liveEvent(eva: eva, category: category, number: number, time: time, side: .departure) {
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

    /// Fills in the departure/arrival platform of any of `journey`'s train legs that Transitous left
    /// without one – whole feeds carry no track at all (e.g. every DB Regio NRW and National Express
    /// train at Aachen Hbf) and others only now and then, for ICEs and RJs as much as regional trains –
    /// using DB's own boards, as DB Navigator shows it.
    public func fillMissingPlatforms(in journey: Journey) async -> Journey {
        var journey = journey
        await withTaskGroup(of: (Int, PlatformInfo?, PlatformInfo?).self) { group in
            for index in journey.legs.indices {
                let leg = journey.legs[index]
                let needsDeparture = leg.departurePlatform?.best == nil
                let needsArrival = leg.arrivalPlatform?.best == nil
                guard needsDeparture || needsArrival, !leg.isWalking, let line = leg.line,
                      let number = line.dispatchNumber, let category = Self.category(from: line.name) else { continue }
                group.addTask {
                    var departurePlatform: PlatformInfo?
                    var arrivalPlatform: PlatformInfo?
                    if needsDeparture, let eva = await self.eva(for: leg.origin),
                       let event = await self.liveEvent(eva: eva, category: category, number: number, time: leg.departure.planned,
                                                        side: .departure) {
                        departurePlatform = Self.mergedPlatform(existing: leg.departurePlatform, event: event)
                    }
                    if needsArrival, let eva = await self.eva(for: leg.destination),
                       let event = await self.liveEvent(eva: eva, category: category, number: number, time: leg.arrival.planned,
                                                        side: .arrival) {
                        arrivalPlatform = Self.mergedPlatform(existing: leg.arrivalPlatform, event: event)
                    }
                    return (index, departurePlatform, arrivalPlatform)
                }
            }
            for await (index, departurePlatform, arrivalPlatform) in group {
                if let departurePlatform { journey.legs[index].departurePlatform = departurePlatform }
                if let arrivalPlatform { journey.legs[index].arrivalPlatform = arrivalPlatform }
            }
        }
        return journey
    }

    /// Fills in a missing platform for any of `entries` – e.g. reported for Berlin Gesundbrunnen,
    /// where Transitous carries a platform for U-Bahn departures but not for the S-Bahn ones at the
    /// very same board, apparently a gap in S-Bahn Berlin's own feed rather than anything DB Navigator
    /// hits – using DB's own boards. Only queried for entries actually missing a
    /// platform, and only one `eva` lookup for the whole board since every entry shares `station`.
    public func fillMissingPlatforms(in entries: [BoardEntry], at station: Station) async -> [BoardEntry] {
        guard let eva = await eva(for: station) else { return entries }
        var entries = entries
        await withTaskGroup(of: (Int, PlatformInfo?).self) { group in
            for index in entries.indices {
                let entry = entries[index]
                guard entry.platform.best == nil, let number = entry.line.dispatchNumber,
                      let category = Self.category(from: entry.line.name) else { continue }
                group.addTask {
                    let event = await self.liveEvent(eva: eva, category: category, number: number, time: entry.time.planned,
                                                     side: entry.kind == .arrivals ? .arrival : .departure)
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

    /// `entries` (one station's board) with DB OpenBoards' live data laid over every train, as the stop lists
    /// do (`stopoversWithRealtime`): a delay or early time DB reports wins over bahn.de's and Transitous', a
    /// cancellation DB reports or doesn't report wins too, a platform swap is overlaid. A train DB reports no
    /// live time for keeps the time it had, or counts as on time once it is about to run (`infersOnTime`). A
    /// train DB can't find, or every train when the board can't be had (it would otherwise read as "on time,
    /// running"), stays as it was. A few boards serve the whole list (cached, requests for the same board merged).
    public func applyingRealtime(to entries: [BoardEntry], at station: Station, now: Date = .now) async -> [BoardEntry] {
        guard let eva = await eva(for: station) else { return entries }
        var entries = entries
        await withTaskGroup(of: (Int, OpenBoardsEvent?).self) { group in
            for index in entries.indices {
                let entry = entries[index]
                guard entry.line.product.isTrain, let number = entry.line.dispatchNumber,
                      let category = Self.category(from: entry.line.name),
                      Self.knowsChanges(until: entry.time.planned, now: now) else { continue }
                group.addTask {
                    let event = await self.liveEvent(eva: eva, category: category, number: number, time: entry.time.planned,
                                                     side: entry.kind == .arrivals ? .arrival : .departure)
                    return (index, event)
                }
            }
            for await (index, event) in group {
                guard let event else { continue }
                entries[index] = Self.applying(event, to: entries[index], now: now)
            }
        }
        return entries
    }

    static func applying(_ event: OpenBoardsEvent, to entry: BoardEntry, now: Date) -> BoardEntry {
        var entry = entry
        let onTime = infersOnTime(departing: entry.time.planned, now: now)
        entry.time.actual = event.actual ?? entry.time.actual ?? (onTime ? entry.time.planned : nil)
        entry.cancelled = event.cancelled
        if let platform = mergedPlatform(existing: entry.platform, event: event) { entry.platform = platform }
        return entry
    }

    /// Every scheduled departure at `station` matching `category` (optional, case-insensitive)
    /// and `number`, across the requested window – straight from DB's own departure board, which lists
    /// every train by its real category and number regardless of how any particular
    /// journey-planning feed brands or names it. Used to confirm a user-named train really exists and
    /// find its true scheduled time when another provider's board doesn't carry it under a matching
    /// name (different branding – e.g. an ÖBB "RJ" that DB's own feed calls "ICE" – or misses the
    /// departure from its board data entirely): see `TrainRoutePlanner`'s use of this for "Bestimmter
    /// Zug". Returns an empty array (rather than throwing) on any failure, since this is always a
    /// best-effort supplement to another provider's board, never the primary source.
    public func scheduledTimes(category: String?, number: String, at station: Station,
                               from: Date, duration: Int) async -> [Date] {
        guard let eva = await eva(for: station) else { return [] }
        let end = from.addingTimeInterval(TimeInterval(duration * 60))
        let hours = Self.planHours(from: from, duration: duration)
        let evas = [eva] + (Self.lowerLevels[eva] ?? [])

        let entries = await withTaskGroup(of: [OpenBoardsEntry].self) { group in
            for hour in hours {
                group.addTask { (try? await self.board(.departure, evas: evas, from: hour, to: hour.addingTimeInterval(3600))) ?? [] }
            }
            var all: [OpenBoardsEntry] = []
            for await page in group { all += page }
            return all
        }

        return entries
            .filter { entry in
                (category.map(entry.isCategory) ?? true)
                    && entry.number.map { Self.sameNumber($0, number) } == true
            }
            .compactMap(\.event.planned)
            .filter { $0 >= from.addingTimeInterval(-60) && $0 <= end }
            .sorted()
    }

    /// The hour buckets covering `from … from + duration`. The cursor starts at the beginning of
    /// `from`'s hour (Berlin time), so the bucket holding the window's end is included even when `from`
    /// isn't on the full hour. The count is capped so a generous window
    /// (e.g. the custom-train picker's default 8h) can't fire dozens of concurrent requests.
    static func planHours(from: Date, duration: Int) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let end = from.addingTimeInterval(TimeInterval(duration * 60))
        var hours: [Date] = []
        var cursor = calendar.dateInterval(of: .hour, for: from)?.start ?? from
        repeat {
            hours.append(cursor)
            cursor = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? cursor.addingTimeInterval(3600)
        } while cursor < end && hours.count < 10
        return hours
    }

    /// "ICE 571" -> "ICE". Also handles names with no space between category and number ("S15" -> "S",
    /// as Transitous names S-Bahn lines) by taking the leading non-digit run of the first token, since
    /// DB always splits them into a separate category and number.
    static func category(from lineName: String) -> String? {
        guard let first = lineName.split(separator: " ").first else { return nil }
        let letters = first.prefix(while: { !$0.isNumber })
        return letters.isEmpty ? nil : letters.uppercased()
    }

    /// The entry in `entries` for train `category`+`number` whose planned time is closest to
    /// `plannedTime` (and within `matchTolerance`). A train whose category matches neither DB's own
    /// category nor its line name still counts when its number and time do – the same number at the
    /// same station within minutes is that train, however each feed brands it (e.g. an ÖBB "RJ" that
    /// Transitous calls "ICE"). Before this, every private operator's train (NX, ARV, HLB, ME, VIA, …)
    /// failed the lookup, so boards, trips and journeys showed no Gleis where Transitous had none.
    static func match(_ entries: [OpenBoardsEntry], category: String, number: String, plannedTime: Date) -> OpenBoardsEntry? {
        let sameNumber = entries.filter { $0.number.map { Self.sameNumber($0, number) } == true }
        let sameCategory = sameNumber.filter { $0.isCategory(category) }
        return closest(sameCategory, to: plannedTime) ?? closest(sameNumber, to: plannedTime)
    }

    private static func closest(_ entries: [OpenBoardsEntry], to plannedTime: Date) -> OpenBoardsEntry? {
        entries
            .compactMap { entry -> (OpenBoardsEntry, TimeInterval)? in
                guard let planned = entry.event.planned else { return nil }
                return (entry, abs(planned.timeIntervalSince(plannedTime)))
            }
            .min { $0.1 < $1.1 }
            .flatMap { $0.1 <= matchTolerance ? $0.0 : nil }
    }

    /// Train numbers sometimes carry leading zeros; compare numerically when possible.
    static func sameNumber(_ a: String, _ b: String) -> Bool {
        if let x = Int(a), let y = Int(b) { return x == y }
        return a == b
    }
}

/// Reads the JSON of an OpenBoards `departures` or `arrivals` response (`departures`/`arrivals` entries
/// plus a `messages` container the entries point into by id).
enum OpenBoardsParser {
    static func parse(_ data: Data, side: BoardSide) throws -> [OpenBoardsEntry] {
        let response = try JSONDecoding.decoder.decode(Response.self, from: data)
        let codes = response.messages?.codesByID ?? [:]
        return ((side == .arrival ? response.arrivals : response.departures) ?? []).compactMap { entry(from: $0, codes: codes) }
    }

    private static func entry(from item: Response.Item, codes: [Int: Int]) -> OpenBoardsEntry? {
        guard let planned = item.timeSchedule else { return nil }
        let cancelled = item.cancelled == true || item.journeyInfo?.journeyCancelled == true
        // A cancelled additional stop was never part of the plan.
        if item.additional == true, item.cancelled == true { return nil }
        // `time` is the best known time; it only counts as live when DB reports it really ran or differs
        // from the schedule. A forecast equal to the schedule says nothing about a train hours away.
        let actual = item.time.flatMap { $0 != planned || item.timeType == "REAL" ? $0 : nil }
        let plannedPlatform = item.platformSchedule?.name ?? item.platform?.name
        let actualPlatform = item.platformSchedule?.name != nil && item.platform?.name != item.platformSchedule?.name
            ? item.platform?.name : nil
        let transport = item.transport
        let number = transport?.journeyNumber.map(String.init) ?? transport?.operationalJourneyNumber
        let event = OpenBoardsEvent(planned: planned, actual: actual, plannedPlatform: plannedPlatform,
                                    actualPlatform: actualPlatform, cancelled: cancelled,
                                    messages: (item.messages ?? []).compactMap { codes[$0] }.map { OpenBoardsMessage(code: $0, timestamp: nil) })
        return OpenBoardsEntry(category: transport?.category, categoryInternal: transport?.categoryInternal, number: number,
                               lineName: transport?.line?.name, event: event)
    }

    private struct Response: Decodable {
        var departures: [Item]?
        var arrivals: [Item]?
        var messages: Messages?

        struct Item: Decodable {
            var cancelled: Bool?
            var additional: Bool?
            var time: Date?
            var timeSchedule: Date?
            var timeType: String?
            var platform: Platform?
            var platformSchedule: Platform?
            var messages: [Int]?
            var transport: Transport?
            var journeyInfo: JourneyInfo?
        }

        struct Platform: Decodable {
            var name: String?
        }

        struct Transport: Decodable {
            var category: String?
            var categoryInternal: String?
            var journeyNumber: Int?
            var operationalJourneyNumber: String?
            var line: Line?
        }

        struct Line: Decodable {
            var name: String?
        }

        struct JourneyInfo: Decodable {
            var journeyCancelled: Bool?
        }

        /// The delay-reason (`risCauseCodes`) and quality (`risQualityDeviations`) messages, which the entries
        /// point to by `messageID`; their `code` is the same number as IRIS's (see `TrainMessageCodes`).
        struct Messages: Decodable {
            var risCauseCodes: [Code]?
            var risQualityDeviations: [Code]?

            struct Code: Decodable {
                var code: String?
                var messageID: Int?
            }

            var codesByID: [Int: Int] {
                var result: [Int: Int] = [:]
                for message in (risCauseCodes ?? []) + (risQualityDeviations ?? []) {
                    if let id = message.messageID, let code = message.code.flatMap({ Int($0) }) { result[id] = code }
                }
                return result
            }
        }
    }
}
