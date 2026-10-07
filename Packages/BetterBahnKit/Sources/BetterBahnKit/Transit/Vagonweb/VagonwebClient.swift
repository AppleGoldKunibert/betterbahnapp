import Foundation

/// vagonweb.cz's train compositions ("Řazení vlaků"), with permission from vagonweb. They have the
/// scheduled composition of a train for the whole timetable year, so they are the source for the
/// train type and the planned Wagenreihung whenever bahn.de has no coach sequence (yet); bahn.expert
/// is the fallback when vagonweb has nothing.
///
/// vagonweb has no API: the train's page is loaded and read (`VagonwebComposition.scheduled`). It sits
/// behind Cloudflare's bot check, which may turn plain requests away; then the page is loaded with
/// `browserLoader` (the app passes one that uses a hidden web view, which can pass the check).
/// Pages are cached per train and timetable year, so each one is only fetched once per launch.
public struct VagonwebClient: Sendable {
    public static let baseURL = URL(string: "https://www.vagonweb.cz")!

    /// Loads a page's HTML like a browser does.
    public typealias PageLoader = @Sendable (URL) async throws -> String

    let http: HTTPClient
    let browserLoader: PageLoader?
    let cache = Cache()

    public init(http: HTTPClient = HTTPClient(timeout: 12), browserLoader: PageLoader? = nil) {
        self.http = http
        self.browserLoader = browserLoader
    }

    // MARK: Lookup

    /// The scheduled composition of a DB train on `date`; nil if vagonweb has none for it.
    /// - Parameters:
    ///   - category: e.g. "ICE".
    ///   - number: e.g. "377".
    public func composition(category: String, number: String, on date: Date) async throws -> VagonwebComposition? {
        guard Int(number) != nil else { throw TransitError.invalidInput("Zugnummer ungültig.") }
        let url = Self.trainURL(category: category, number: number, timetableYear: Self.timetableYear(of: date))
        let compositions = try await compositions(at: url)
        // A composition for the day if vagonweb has dated ones, else the one for the whole year.
        return compositions.first { $0.validFrom != nil && $0.applies(on: date) }
            ?? compositions.first { $0.validFrom == nil && $0.validUntil == nil }
    }

    /// The train type ("ICE 4", "2× ICE 3" …) from the scheduled composition; nil if vagonweb has no
    /// composition or it isn't one of the ICE series.
    public func trainType(category: String, number: String, on date: Date) async throws -> TrainTypeLookup? {
        guard let composition = try await composition(category: category, number: number, on: date) else { return nil }
        let lookup = composition.trainType(category: category, number: number, date: BahnDeClient.berlinDay(date))
        return lookup.summary == nil ? nil : lookup
    }

    /// The planned Wagenreihung from the scheduled composition (no platform positions or sectors).
    public func coachSequence(category: String, number: String, on date: Date) async throws -> CoachSequence? {
        guard let composition = try await composition(category: category, number: number, on: date) else { return nil }
        return composition.coachSequence(trainName: "\(category.uppercased()) \(number)")
    }

    /// The planned Wagenreihung for a long-distance train at a stop; nil for regional trains. vagonweb
    /// has the whole train as it leaves its first station, so it is turned round when the train
    /// changed direction on the way (`reversals(at:route:in:)`).
    /// - Parameter route: the train's stops from its first one up to the request's station. Without
    ///   it the direction stays unknown.
    public func coachSequence(for request: BahnDeClient.FormationRequest, route: [String]? = nil) async throws -> CoachSequence? {
        guard BahnDeClient.longDistanceCategories.contains(request.category.uppercased()),
              let composition = try await composition(category: request.category, number: request.number, on: request.plannedDeparture)
        else { return nil }
        var sequence = composition.coachSequence(trainName: "\(request.category.uppercased()) \(request.number)")
        let candidates = composition.reversalStations + Self.terminusStations
        if let route, let reversals = Self.reversals(at: request.station.name, route: route, in: candidates) {
            sequence = sequence.turned(after: reversals)
            // vagonweb draws the front of the train first, which the diagram puts at the top.
            sequence.travelsTowardsPlatformEnd = false
        }
        return sequence
    }

    /// Stations where trains always change direction (terminus stations they go on from), for
    /// compositions whose vagonweb note doesn't say.
    static let terminusStations = [
        "Frankfurt (Main) Hbf", "Leipzig Hbf", "Stuttgart Hbf", "München Hbf", "Wiesbaden Hbf", "Kiel Hbf",
        "Lindau-Insel", "Lindau Hbf", "Hamburg-Altona", "Basel SBB", "Zürich HB",
    ]

    /// The stations of `route` (its first stop left out, `station` included) where the train changes
    /// direction; nil when `station` isn't on the route.
    static func reversals(at station: String, route: [String], in candidates: [String]) -> [String]? {
        let key = stationKey(station)
        guard let index = route.lastIndex(where: { stationKey($0) == key }) else { return nil }
        let reversing = Set(candidates.map(stationKey))
        return route[..<route.index(after: index)].dropFirst().filter { reversing.contains(stationKey($0)) }
    }

    /// Station names reduced to compare vagonweb's with DB's and Transitous's: "Frankfurt(Main)Hbf",
    /// "Frankfurt (Main) Hauptbahnhof" and "Frankfurt (M) Hbf" all become "frankfurtmain".
    public static func stationKey(_ name: String) -> String {
        var key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "hauptbahnhof", with: "hbf")
            .replacingOccurrences(of: "(m)", with: "(main)")
        key = String(key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        for suffix in ["hbf", "hb"] where key.hasSuffix(suffix) && key.count > suffix.count {
            key.removeLast(suffix.count)
            break
        }
        return key
    }

    // MARK: Fetching

    /// Pages already read, and the ones being loaded, so a train's page is only asked for once even
    /// when several views want it at the same time.
    actor Cache {
        var pages: [URL: (compositions: [VagonwebComposition], loadedAt: Date)] = [:]
        var loading: [URL: Task<[VagonwebComposition], any Error>] = [:]
        /// vagonweb turned every way of loading away; don't ask again for a while.
        var blockedUntil: Date?

        func compositions(at url: URL, load: @escaping @Sendable () async throws -> String) async throws -> [VagonwebComposition] {
            if let entry = pages[url], Date.now.timeIntervalSince(entry.loadedAt) < 6 * 3600 { return entry.compositions }
            if let task = loading[url] { return try await task.value }
            if let blockedUntil, Date.now < blockedUntil { throw TransitError.rateLimited }
            let task = Task { VagonwebComposition.scheduled(fromHTML: try await load()) }
            loading[url] = task
            defer { loading[url] = nil }
            do {
                let compositions = try await task.value
                pages[url] = (compositions, .now)
                return compositions
            } catch TransitError.rateLimited {
                blockedUntil = Date.now.addingTimeInterval(10 * 60)
                throw TransitError.rateLimited
            }
        }
    }

    func compositions(at url: URL) async throws -> [VagonwebComposition] {
        try await cache.compositions(at: url) { try await page(at: url) }
    }

    /// The page's HTML: a plain request first, the browser loader when Cloudflare's check answers.
    /// Asked for without a previous visit, vagonweb shows only an "anzeigen" link to the same page
    /// (`isGate`); then the scheduled compositions are asked for directly, as vagonweb's page does
    /// (`plannedCompositionsRequest`), or the page again, as from that link.
    func page(at url: URL) async throws -> String {
        do {
            for attempt in 0..<3 {
                var request = URLRequest(url: url, timeoutInterval: http.timeout)
                request.setValue("text/html", forHTTPHeaderField: "Accept")
                if attempt > 0 { request.setValue(url.absoluteString, forHTTPHeaderField: "Referer") }
                let html = String(decoding: try await http.sendRaw(request), as: UTF8.self)
                if Self.isChallenge(html) { break }
                if !Self.isGate(html) { return html }
                // The request vagonweb's own page sends for "show all planned compositions".
                if attempt == 0, let request = Self.plannedCompositionsRequest(for: url),
                   let data = try? await http.sendRaw(request) {
                    let part = String(decoding: data, as: UTF8.self)
                    if !VagonwebComposition.scheduled(fromHTML: part).isEmpty { return part }
                }
            }
        } catch TransitError.http(let status, _) where [403, 503].contains(status) {
            // Cloudflare's check, or its block page: a browser may still get through.
        } catch TransitError.http(let status, _) where status == 404 {
            throw TransitError.notFound(url.absoluteString)
        }
        guard let browserLoader else { throw TransitError.rateLimited }
        let html = try await browserLoader(url)
        guard !Self.isChallenge(html), !Self.isGate(html) else { throw TransitError.rateLimited }
        return html
    }

    /// `ajax_dalsi_razeni_vlak.php` with `vsechny_planovane`: all scheduled compositions of the train
    /// as an HTML fragment, what vagonweb's page loads when its calendar's "all" is tapped.
    static func plannedCompositionsRequest(for pageURL: URL) -> URLRequest? {
        let query = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        guard let number = value("cislo"), let year = value("rok") else { return nil }
        var form = URLComponents()
        form.queryItems = [
            ("rok", year), ("zeme", value("zeme") ?? "DB"), ("cislo", number), ("nazev", "_n_"), ("styl", "r"),
            ("aktualni_rok", year), ("cislo_vozu", ""), ("od", ""), ("do_x", ""), ("virtualni_vlak", ""),
            ("cislo_alias", ""), ("vsechny_planovane", "1"),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: baseURL.appending(path: "razeni/ajax_dalsi_razeni_vlak.php"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return request
    }

    /// vagonweb's page before "anzeigen": the train's route, then only a link to show its compositions.
    public static func isGate(_ html: String) -> Bool {
        !html.contains("id='planovane_razeni'") && html.contains("<h2>&raquo; <a href=") && html.contains("vlak.php?")
    }

    /// Cloudflare's "Just a moment…" interstitial instead of the page.
    public static func isChallenge(_ html: String) -> Bool {
        html.contains("_cf_chl_opt") || html.contains("<title>Just a moment...</title>")
    }

    // MARK: Helpers

    /// `https://www.vagonweb.cz/razeni/vlak.php?zeme=DB&kategorie=ICE&cislo=377&rok=2026&lang=en`.
    /// English, so the page reads the same whatever language vagonweb would pick.
    public static func trainURL(category: String, number: String, timetableYear: Int) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "razeni/vlak.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "zeme", value: "DB"),
            URLQueryItem(name: "kategorie", value: category.uppercased()),
            URLQueryItem(name: "cislo", value: number),
            URLQueryItem(name: "rok", value: String(timetableYear)),
            URLQueryItem(name: "lang", value: "en"),
        ]
        return components.url!
    }

    /// vagonweb files compositions by timetable year, which starts with the timetable change on the
    /// second Sunday of December: 14 December 2025 is already in 2026.
    public static func timetableYear(of date: Date) -> Int {
        let calendar = VagonwebComposition.calendar
        let year = calendar.component(.year, from: date)
        var components = DateComponents(year: year, month: 12, weekday: 1, weekdayOrdinal: 2)
        components.hour = 0
        guard let change = calendar.date(from: components) else { return year }
        return date >= change ? year + 1 : year
    }
}

// MARK: - Mapping

extension VagonwebComposition {
    /// ICE Baureihen `TrainTypeLookup.Group.family` knows.
    static let iceBaureihen: Set<String> = ["401", "402", "403", "406", "407", "408", "411", "412", "415"]

    /// The ICE series of a trainset, by the drawings of most of its coaches.
    static func baureihe(of unit: [Coach]) -> String? {
        var votes: [String: Int] = [:]
        for baureihe in unit.compactMap(\.baureihe) where iceBaureihen.contains(baureihe) { votes[baureihe, default: 0] += 1 }
        return votes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    func trainType(category: String, number: String, date: String) -> TrainTypeLookup {
        TrainTypeLookup(
            category: category.uppercased(), number: number, date: date, administration: BahnDeClient.dbAdministration,
            groups: units.map { unit in
                TrainTypeLookup.Group(seriesName: nil, baureihe: Self.baureihe(of: unit), unitNumber: nil,
                                      origin: nil, destination: nil, coachCount: unit.count)
            },
            status: .planned, source: "vagonweb", retrievedAt: .now)
    }

    func coachSequence(trainName: String) -> CoachSequence {
        let units = units
        var groups: [CoachSequence.Group] = []
        var coaches: [CoachSequence.Coach] = []
        for unit in units {
            let baureihe = Self.baureihe(of: unit)
            let model = TrainTypeLookup.Group(seriesName: nil, baureihe: baureihe, unitNumber: nil, origin: nil,
                                              destination: nil, coachCount: unit.count).family
            groups.append(CoachSequence.Group(trainName: trainName, destination: nil,
                                              unit: model.map { TrainFormation.Unit(model: $0, number: nil) },
                                              isRequestedTrain: true))
            for coach in unit {
                let kind: CoachSequence.Coach.Kind =
                    if !coach.hasSeats { baureihe == nil ? .locomotive : .powerCar }
                    else if coach.diningSeats != nil || coach.hasBar {
                        coach.firstClass || coach.secondClass ? .halfDiningCar : .diningCar
                    } else { .passenger }
                coaches.append(CoachSequence.Coach(
                    id: coaches.count,
                    number: kind == .locomotive || kind == .powerCar ? nil : coach.number,
                    kind: kind,
                    firstClass: coach.firstClass,
                    secondClass: coach.secondClass,
                    closed: false,
                    amenities: Self.amenities(of: coach),
                    bikeSpaces: coach.bikeSpaces.flatMap { $0 > 0 ? $0 : nil },
                    start: nil, end: nil, sector: nil,
                    group: groups.count - 1))
            }
        }
        return CoachSequence(
            platform: nil, platformLength: nil, sectors: [], groups: groups, coaches: coaches,
            travelsTowardsPlatformEnd: nil, differsFromSchedule: false,
            formation: TrainFormation(units: groups.compactMap(\.unit)),
            source: .vagonweb(validFrom: validFrom, validUntil: validUntil))
    }

    /// From the coach's icons and vagonweb's notes ("quiet zone", "seats 61-78 family area" …).
    static func amenities(of coach: Coach) -> [CoachSequence.Coach.Amenity] {
        let notes = coach.notes.joined(separator: " ").lowercased()
        return CoachSequence.Coach.Amenity.allCases.filter { amenity in
            switch amenity {
            case .bikeSpace: (coach.bikeSpaces ?? 0) > 0 || notes.contains("bicycle") || notes.contains("fahrrad")
            case .wheelchairSpace: coach.wheelchairSpaces != nil || notes.contains("wheelchair") || notes.contains("rollstuhl")
            case .wheelchairToilet: false
            case .severelyDisabledSeats: notes.contains("disabled") || notes.contains("behindert")
            case .quietZone: notes.contains("quiet") || notes.contains("ruhe")
            case .familyZone: notes.contains("famil")
            case .infantCabin: notes.contains("childern") || notes.contains("children") || notes.contains("kleinkind")
            case .bahnComfortSeats: notes.contains("bahn.comfort") || notes.contains("bahncomfort")
            case .info: coach.hasInfoPoint
            }
        }
    }
}
