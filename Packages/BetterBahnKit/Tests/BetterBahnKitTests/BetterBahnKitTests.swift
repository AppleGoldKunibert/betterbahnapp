import Foundation
import Testing
@testable import BetterBahnKit

func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoding.decoder.decode(T.self, from: Data(contentsOf: url))
}

func station(_ id: String, _ name: String, _ lat: Double? = nil, _ lon: Double? = nil, source: DataSource = .dbRest) -> Station {
    Station(id: id, name: name, coordinate: lat.flatMap { lat in lon.map { Coordinate(latitude: lat, longitude: $0) } },
            evaNumber: source == .dbRest ? id : nil, source: source)
}

// MARK: - db-rest mapping

@Suite struct DBRestMappingTests {
    @Test func departures() throws {
        let response = try fixture("dbrest-departures", as: DBBoardResponse.self)
        let fallback = station("8000207", "Köln Hbf")
        let entries = response.items.compactMap { $0.toEntry(kind: .departures, fallbackStation: fallback) }
        #expect(entries.count == 2)
        let ice = entries[0]
        #expect(ice.line.name == "ICE 423")
        #expect(ice.line.product == .highSpeed)
        #expect(ice.time.delayMinutes == 5)
        #expect(ice.platform.hasChanged)
        #expect(ice.otherEnd == "Berlin Hbf")
        #expect(ice.terminatesOrOriginatesHere == false)
        #expect(ice.remarks == ["Bauarbeiten"])
        #expect(entries[1].cancelled)
        #expect(entries[1].time.actual == nil)
    }

    @Test func journeys() throws {
        let response = try fixture("dbrest-journeys", as: DBJourneysResponse.self)
        let legs = try #require(response.journeys.first).legs.compactMap { $0.toLeg() }
        let journey = Journey(legs: legs, source: .dbRest)
        #expect(legs.count == 3)
        #expect(legs[1].isWalking)
        #expect(journey.transfers == 1)
        #expect(journey.transitLegs.map { $0.line?.name } == ["ICE 423", "RE 6"])
        #expect(legs[0].stopovers.count == 2)
        #expect(journey.brokenTransferIndices.isEmpty)
    }

    @Test func tripLegSlicing() throws {
        let response = try fixture("dbrest-trip", as: DBTripResponse.self)
        let trip = Trip(id: response.trip.id, line: response.trip.line?.toLine(), direction: response.trip.direction,
                        stopovers: (response.trip.stopovers ?? []).compactMap { $0.toStopover() },
                        cancelled: false, remarks: [], source: .dbRest)
        let leg = try #require(trip.leg(from: station("8000085", "Düsseldorf Hbf"), to: station("8011160", "Berlin Hbf")))
        #expect(leg.stopovers.count == 3)
        #expect(leg.line?.name == "ICE 423")
        // Wrong direction is not a valid leg.
        #expect(trip.leg(from: station("8011160", "Berlin Hbf"), to: station("8000207", "Köln Hbf")) == nil)
    }
}

// MARK: - Transitous mapping

@Suite struct TransitousMappingTests {
    @Test func stopTimes() throws {
        let response = try fixture("transitous-stoptimes", as: MStopTimesResponse.self)
        let entries = response.stopTimes.compactMap { $0.toEntry(kind: .departures) }
        #expect(entries.count == 3)
        let first = try #require(entries.first)
        #expect(first.line.name == "RB25 (10574)" || first.line.product == .regional)
        #expect(first.source == .transitous)
    }

    @Test func plan() throws {
        let response = try fixture("transitous-plan", as: MPlanResponse.self)
        let journey = Journey(legs: try #require(response.itineraries.first).legs.map { $0.toLeg() }, source: .transitous)
        let transit = journey.transitLegs
        #expect(transit.count == 2)
        #expect(transit[0].line?.name == "ICE 224")
        #expect(transit[0].line?.number == "224")
        #expect(transit[0].line?.product == .highSpeed)
        #expect(transit[0].departure.delayMinutes == 40)
        #expect(transit[0].stopovers.count >= 3)
        #expect(response.nextPageCursor != nil)
    }

    @Test func trip() throws {
        let itinerary = try fixture("transitous-trip", as: MItinerary.self)
        let leg = try #require(itinerary.legs.first).toLeg()
        #expect(leg.origin.name == "München Hbf")
        #expect(leg.stopovers.count == 14)
    }
}

// MARK: - Rules & filters

@Suite struct RulesTests {
    let ice = Line(name: "ICE 423", number: "423", product: .highSpeed, operatorName: "DB Fernverkehr AG")
    let flix = Line(name: "FLX 1245", number: "1245", product: .longDistance, operatorName: "FlixTrain")
    let flixNoOperator = Line(name: "FLX 30", number: "30", product: .longDistance, operatorName: nil)
    let regio = Line(name: "RE 6", number: nil, product: .regionalExpress, operatorName: "National Express")
    let coach = Line(name: "FlixBus N123", number: nil, product: .coach, operatorName: "FlixBus")
    let sleeper = Line(name: "ES 453", number: "453", product: .longDistance, operatorName: "European Sleeper")

    @Test func bc100() {
        let rules = BC100Rules.default
        #expect(rules.isValid(ice))
        #expect(rules.isValid(regio))
        #expect(!rules.isValid(flix))
        #expect(!rules.isValid(flixNoOperator))
        #expect(!rules.isValid(coach))
        #expect(!rules.isValid(sleeper))
    }

    func entry(_ line: Line, kind: BoardKind = .departures, otherEnd: String = "Berlin Hbf", terminal: Bool? = false) -> BoardEntry {
        BoardEntry(kind: kind, tripId: UUID().uuidString, station: station("8000207", "Köln Hbf"), line: line,
                   otherEnd: otherEnd, time: TimeInfo(planned: .now, actual: nil),
                   platform: PlatformInfo(planned: "1", actual: nil), cancelled: false,
                   terminatesOrOriginatesHere: terminal, remarks: [], source: .dbRest)
    }

    @Test func boardKeepsPassingTrainsAndDropsTerminating() {
        let filter = BoardFilter()
        #expect(filter.includes(entry(ice)))
        #expect(filter.includes(entry(ice, terminal: nil)))
        #expect(!filter.includes(entry(ice, otherEnd: "Köln Hbf", terminal: true)))
        #expect(!filter.includes(entry(ice, kind: .arrivals, otherEnd: "Köln Hbf", terminal: true)))
    }

    @Test func boardProductsAndBC100() {
        let filter = BoardFilter(products: [.highSpeed, .longDistance], bc100Rules: .default)
        #expect(filter.includes(entry(ice)))
        #expect(!filter.includes(entry(flix)))
        #expect(!filter.includes(entry(regio)))
    }

    @Test func pkceMatchesRFC7636() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE().verifier.count == 64)
    }

    @Test func lineNormalize() {
        #expect(Line.normalize("ICE  423") == Line.normalize("ice423"))
    }
}

// MARK: - Providers with mocks

final class MockProvider: TransitProvider, @unchecked Sendable {
    let source: DataSource
    var failing = false
    var boards: [BoardEntry] = []
    var trips: [String: Trip] = [:]
    var journeyPages: [JourneyPage] = []
    var calls: [String] = []
    private let lock = NSLock()

    init(source: DataSource) { self.source = source }

    private func record(_ call: String) throws {
        lock.withLock { calls.append(call) }
        if failing { throw TransitError.http(status: 503, body: nil) }
    }

    func searchStations(_ query: String) async throws -> [Station] {
        try record("search")
        return [station("1", query, source: source)]
    }

    func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        try record("journeys")
        return journeyPages.first ?? JourneyPage(journeys: [], earlierCursor: nil, laterCursor: nil, source: source)
    }

    func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int) async throws -> [BoardEntry] {
        try record("board")
        return boards
    }

    func trip(id: String) async throws -> Trip {
        try record("trip")
        guard let trip = trips[id] else { throw TransitError.notFound(id) }
        return trip
    }
}

@Suite struct CombinedProviderTests {
    @Test func fallsBackAndCoolsDown() async throws {
        let primary = MockProvider(source: .dbRest)
        primary.failing = true
        let fallback = MockProvider(source: .transitous)
        let combined = CombinedProvider(primary: primary, fallback: fallback, bahnDe: nil, cooldown: 60)

        let first = try await combined.searchStations("Köln")
        #expect(first.first?.source == .transitous)
        _ = try await combined.searchStations("Köln")
        // Second call skips the failing primary during cooldown.
        #expect(primary.calls.count == 1)
        #expect(fallback.calls.count == 2)
    }

    @Test func usesPrimaryWhenHealthy() async throws {
        let primary = MockProvider(source: .dbRest)
        let fallback = MockProvider(source: .transitous)
        let combined = CombinedProvider(primary: primary, fallback: fallback, bahnDe: nil)
        let result = try await combined.searchStations("Köln")
        #expect(result.first?.source == .dbRest)
        #expect(fallback.calls.isEmpty)
    }

    @Test func cursorPrefix() {
        #expect(CombinedProvider.cursorSource("transitous:abc") == .transitous)
        #expect(CombinedProvider.stripCursor("dbRest:laterThan=x", source: .dbRest) == "laterThan=x")
        #expect(CombinedProvider.stripCursor("dbRest:laterThan=x", source: .transitous) == nil)
    }
}

@Suite struct TrainPickerTests {
    let koeln = station("8000207", "Köln Hbf", 50.943, 6.958)
    let duesseldorf = station("8000085", "Düsseldorf Hbf", 51.219, 6.794)
    let berlin = station("8011160", "Berlin Hbf", 52.525, 13.369)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func stop(_ s: Station, arr: Double?, dep: Double?) -> Stopover {
        Stopover(station: s, arrival: arr.map { TimeInfo(planned: base.addingTimeInterval($0 * 60), actual: nil) },
                 departure: dep.map { TimeInfo(planned: base.addingTimeInterval($0 * 60), actual: nil) },
                 arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    func trip(_ id: String, _ name: String, _ stops: [Stopover]) -> Trip {
        Trip(id: id, line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed, operatorName: "DB Fernverkehr AG"),
             direction: "Berlin Hbf", stopovers: stops, cancelled: false, remarks: [], source: .dbRest)
    }

    func boardEntry(_ trip: Trip, minutes: Double) -> BoardEntry {
        BoardEntry(kind: .departures, tripId: trip.id, station: koeln, line: trip.line!, otherEnd: "Berlin Hbf",
                   time: TimeInfo(planned: base.addingTimeInterval(minutes * 60), actual: nil),
                   platform: PlatformInfo(planned: nil, actual: nil), cancelled: false,
                   terminatesOrOriginatesHere: false, remarks: [], source: .dbRest)
    }

    func makePicker() -> (TrainPicker, Trip, Trip) {
        let fast = trip("ice1", "ICE 1", [stop(koeln, arr: nil, dep: 0), stop(berlin, arr: 240, dep: nil)])
        let slow = trip("ice423", "ICE 423", [stop(koeln, arr: nil, dep: 10), stop(duesseldorf, arr: 30, dep: 32), stop(berlin, arr: 290, dep: nil)])
        let other = trip("ice999", "ICE 999", [stop(koeln, arr: nil, dep: 20), stop(duesseldorf, arr: 40, dep: nil)])
        let primary = MockProvider(source: .dbRest)
        primary.boards = [boardEntry(fast, minutes: 0), boardEntry(slow, minutes: 10), boardEntry(other, minutes: 20)]
        primary.trips = ["ice1": fast, "ice423": slow, "ice999": other]
        let provider = CombinedProvider(primary: primary, fallback: MockProvider(source: .transitous), bahnDe: nil)
        return (TrainPicker(provider: provider), fast, slow)
    }

    @Test func alternativesOnlyIncludeTrainsReachingDestination() async throws {
        let (picker, fast, _) = makePicker()
        let leg = try #require(fast.leg(from: koeln, to: berlin))
        let alternatives = try await picker.alternatives(for: leg)
        #expect(alternatives.map { $0.line?.name } == ["ICE 423"])
    }

    @Test func forceTrainByName() async throws {
        let (picker, _, _) = makePicker()
        let journey = try await picker.journey(withTrain: "ice423", from: koeln, to: berlin, date: base)
        #expect(journey.legs.count == 1)
        #expect(journey.legs[0].line?.name == "ICE 423")
        let byNumber = try await picker.journey(withTrain: "423", from: koeln, to: berlin, date: base)
        #expect(byNumber.legs[0].tripId == "ice423")
        await #expect(throws: TransitError.self) {
            try await picker.journey(withTrain: "ICE 999", from: koeln, to: berlin, date: base)
        }
    }

    @Test func replaceLastLeg() async throws {
        let (picker, fast, slow) = makePicker()
        let journey = Journey(legs: [try #require(fast.leg(from: koeln, to: berlin))], source: .dbRest)
        let newLeg = try #require(slow.leg(from: koeln, to: berlin))
        let replaced = try await picker.replacing(legAt: 0, in: journey, with: newLeg, finalDestination: berlin)
        #expect(replaced.legs.map(\.tripId) == ["ice423"])
    }
}

@Suite struct AccessAndDeadlineTests {
    @Test func stopAccessFilter() {
        func entry(_ access: StopAccess) -> BoardEntry {
            BoardEntry(kind: .departures, tripId: UUID().uuidString, station: station("1", "Köln Hbf"),
                       line: Line(name: "ICE 1", number: "1", product: .highSpeed, operatorName: nil), otherEnd: "Berlin Hbf",
                       time: TimeInfo(planned: .now, actual: nil), platform: PlatformInfo(planned: nil, actual: nil),
                       cancelled: false, terminatesOrOriginatesHere: false, remarks: [], access: access, source: .transitous)
        }
        let filter = BoardFilter()
        #expect(!filter.includes(entry(.passThrough)))
        #expect(filter.includes(entry(.exitOnly)))
        #expect(filter.includes(entry(.normal)))
        #expect(StopAccess(pickupAllowed: false, dropoffAllowed: true) == .exitOnly)
        #expect(DBRemark.access([DBRemark(type: "hint", text: "Kein Einstieg möglich", summary: nil)]) == .exitOnly)
    }

    final class SlowProvider: TransitProvider, @unchecked Sendable {
        let source = DataSource.dbRest
        func searchStations(_ query: String) async throws -> [Station] {
            try await Task.sleep(for: .seconds(30))
            return []
        }
        func journeys(_ query: JourneyQuery) async throws -> JourneyPage { throw TransitError.timeout }
        func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int) async throws -> [BoardEntry] { [] }
        func trip(id: String) async throws -> Trip { throw TransitError.timeout }
    }

    @Test func slowPrimaryFallsBackQuickly() async throws {
        let combined = CombinedProvider(primary: SlowProvider(), fallback: MockProvider(source: .transitous), bahnDe: nil)
        let start = Date.now
        let result = try await combined.searchStations("Köln")
        #expect(result.first?.source == .transitous)
        #expect(Date.now.timeIntervalSince(start) < 5)
    }
}

@Suite struct FormationTests {
    @Test func seriesFromConstructionTypes() {
        #expect(BahnDeClient.model(constructionTypes: ["I4080", "I4081"], groupName: "ICE8033", category: "ICE") == "ICE 3neo")
        #expect(BahnDeClient.model(constructionTypes: ["I0812", "I1412", "I1812"], groupName: "ICE9465", category: "ICE") == "ICE 4")
        #expect(BahnDeClient.model(constructionTypes: ["I4010", "I8010"], groupName: "ICE0160", category: "ICE") == "ICE 1")
        #expect(BahnDeClient.model(constructionTypes: ["I4110", "I4115"], groupName: "ICE1162", category: "ICE") == "ICE T")
        #expect(BahnDeClient.model(constructionTypes: ["R8911", "R8921"], groupName: "ICE1811", category: "ICE") == "ICE L")
        #expect(BahnDeClient.model(constructionTypes: ["E1465", "R6682"], groupName: "ICD2854", category: "IC") == "IC 2 (Twindexx)")
    }

    @Test func formationSummary() {
        let formation = TrainFormation(units: [.init(model: "ICE 3neo", number: "8030"), .init(model: "ICE 3neo", number: "8005")])
        #expect(formation.modelSummary == "2× ICE 3neo")
        #expect(formation.unitSummary == "Tz 8030 + 8005")
    }
}

@Suite struct GeometryTests {
    @Test func polylineRoundTrip() {
        let coords = [Coordinate(latitude: 50.943029, longitude: 6.958729), Coordinate(latitude: 51.21996, longitude: 6.794315),
                      Coordinate(latitude: 52.524925, longitude: 13.369629)]
        let decoded = Polyline.decode(Polyline.encode(coords))
        #expect(decoded.count == 3)
        #expect(abs(decoded[2].longitude - 13.369629) < 0.000002)
    }

    @Test func transitousLegHasTrackGeometry() throws {
        let itinerary = try fixture("transitous-leg-geometry", as: MItinerary.self)
        let ice = try #require(itinerary.legs.first).toLeg()
        let geometry = try #require(ice.geometry)
        // Following the tracks is longer than the straight line between Köln and Duisburg.
        let straight = try #require(ice.origin.coordinate).distance(to: try #require(ice.destination.coordinate))
        #expect(geometry.count > 50)
        #expect(Polyline.length(geometry) > straight)
    }

    @Test func slice() {
        let line = (0...10).map { Coordinate(latitude: 50, longitude: 7 + Double($0) * 0.1) }
        let part = Polyline.slice(line, from: Coordinate(latitude: 50, longitude: 7.31), to: Coordinate(latitude: 50, longitude: 7.69))
        #expect(part.count == 5)
    }

    @Test func heatmapCountsOverlaps() {
        let a = (0...20).map { Coordinate(latitude: 50, longitude: 7 + Double($0) * 0.01) }
        let b = (10...30).map { Coordinate(latitude: 50.0001, longitude: 7 + Double($0) * 0.01) } // parallel track
        let runs = SegmentHeatmap().runs(for: [a, b])
        #expect(runs.contains { $0.count == 2 })
        #expect(runs.contains { $0.count == 1 })
        #expect(runs.map(\.count).max() == 2)
    }
}

@Suite struct TraewellingHistoryTests {
    @Test func statusToJourney() throws {
        let page = try fixture("traewelling-statuses", as: TraewellingClient.StatusPage.self)
        #expect(page.data.count == 2)
        #expect(page.links?.next != nil)
        let status = page.data[0]
        let geometry = [Coordinate(latitude: 50.943, longitude: 6.958), Coordinate(latitude: 52.376, longitude: 9.741)]
        let journey = try #require(status.journey(geometry: geometry))
        let leg = try #require(journey.legs.first)
        #expect(leg.line?.product == .highSpeed)
        #expect(leg.line?.name == "ICE 645")
        #expect(leg.departure.delayMinutes == 4)
        #expect(leg.geometry?.count == 2)
        #expect(leg.source == .traewelling)
        #expect(page.data[1].product == .suburban)
    }
}

@Suite struct ConnectionCheckTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func leg(_ line: String, _ from: String, _ to: String, dep: Double, arr: Double, depDelay: Double = 0, arrDelay: Double = 0,
             cancelled: Bool = false, walking: Bool = false) -> Leg {
        Leg(origin: station(from, from), destination: station(to, to),
            departure: TimeInfo(planned: base.addingTimeInterval(dep * 60), actual: base.addingTimeInterval((dep + depDelay) * 60)),
            arrival: TimeInfo(planned: base.addingTimeInterval(arr * 60), actual: base.addingTimeInterval((arr + arrDelay) * 60)),
            departurePlatform: nil, arrivalPlatform: nil, tripId: walking ? nil : line,
            line: walking ? nil : Line(name: line, number: nil, product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: walking, cancelled: cancelled, stopovers: [], remarks: [], source: .dbRest)
    }

    @Test func onTimeHasNoIssues() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60), leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .dbRest)
        #expect(journey.connectionIssues().isEmpty)
    }

    @Test func delayBreaksTransfer() {
        let journey = Journey(legs: [
            leg("ICE 1", "A", "B", dep: 0, arr: 60, arrDelay: 12),
            leg("", "B", "B", dep: 60, arr: 63, walking: true),
            leg("ICE 2", "B", "C", dep: 70, arr: 120),
        ], source: .dbRest)
        let issues = journey.connectionIssues()
        #expect(issues.count == 1)
        guard case .transferMissed(let at, _, _, let buffer) = issues[0] else { Issue.record("wrong issue"); return }
        #expect(at == "B")
        #expect(buffer == -5)
        #expect(issues[0].isBlocking)
    }

    @Test func tightButPossible() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60, arrDelay: 6), leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .dbRest)
        #expect(journey.connectionIssues().first?.isBlocking == false)
    }

    @Test func cancellation() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60, cancelled: true)], source: .dbRest)
        #expect(journey.connectionIssues().first?.title == "ICE 1 fällt aus")
    }
}
