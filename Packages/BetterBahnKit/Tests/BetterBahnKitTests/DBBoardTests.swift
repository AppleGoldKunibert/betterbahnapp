import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// Departure boards from DB first: trains from DB Timetables (IRIS), buses and trams from RIS::Boards, Transitous
/// only when DB has nothing.
@Suite(.serialized) struct DBBoardTests {
    let koeln = Station(id: "8000207", name: "Köln Hbf", coordinate: nil, evaNumber: "8000207", source: .bahnDe)
    /// 2026-11-04 12:00 in Berlin.
    let noon = Date(timeIntervalSince1970: 1_793_790_000)

    func provider(irisKnowsStation: Bool = true, risAnswers: Bool = true) -> (DBBoardProvider, URLSession) {
        DBBoardProtocol.requests.withLock { $0 = [] }
        DBBoardProtocol.irisKnowsStation.withLock { $0 = irisKnowsStation }
        DBBoardProtocol.risAnswers.withLock { $0 = risAnswers }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DBBoardProtocol.self]
        let session = URLSession(configuration: config)
        let http = HTTPClient(session: session)
        let timetables = TimetablesClient(http: http, bahnDe: BahnDeClient(http: http, gate: BahnDeGate()))
        return (DBBoardProvider(timetables: timetables, boards: RISBoardsClient(serverURL: URL(string: "https://proxy.test")!, http: http)), session)
    }

    @Test func noonIsWhatTheFixturesSay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimetablesClient.berlin
        #expect(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: noon)
            == DateComponents(year: 2026, month: 11, day: 4, hour: 12, minute: 0))
    }

    /// Trains from IRIS with fchg's changes, named like Transitous names them; a tram from RIS::Boards.
    @Test func trainsFromIRISTramsFromRISBoards() async throws {
        let (db, session) = provider()
        defer { session.invalidateAndCancel() }
        let entries = try await db.board(.departures, at: koeln, date: noon, duration: 60, products: Set(Product.allCases))
        #expect(entries.map(\.line.name) == ["STR 18", "ICE 22", "RE1 (26832)", "S11", "RB24 (99999)"])
        #expect(entries.allSatisfy { $0.source == .bahnDe })

        let ice = try #require(entries.first { $0.line.name == "ICE 22" })
        #expect(ice.line.product == .highSpeed)
        #expect(ice.otherEnd == "Dortmund Hbf")
        #expect(ice.time.delayMinutes == 7)
        #expect(ice.platform.planned == "4 A-C")
        #expect(ice.platform.actual == "5")
        #expect(ice.terminatesOrOriginatesHere == false)
        #expect(ice.remarks.isEmpty == false)
        let reference = try #require(IRISTripReference(id: ice.tripId))
        #expect(reference.category == "ICE" && reference.number == "22" && reference.eva == "8000207" && reference.kind == .departures)

        let re = try #require(entries.first { $0.line.name == "RE1 (26832)" })
        #expect(re.line.product == .regionalExpress)
        #expect(re.otherEnd == "Aachen Hbf")
        #expect(re.time.actual == nil)

        let s11 = try #require(entries.first { $0.line.name == "S11" })
        #expect(s11.cancelled)
        #expect(s11.line.product == .suburban)
        #expect(s11.terminatesOrOriginatesHere == true)

        // A train only in fchg, added at short notice.
        #expect(entries.contains { $0.line.name == "RB24 (99999)" && $0.otherEnd == "Euskirchen" })
        // Outside the hour asked for.
        #expect(!entries.contains { $0.line.name == "IC 2005" })

        let tram = try #require(entries.first { $0.line.product == .tram })
        #expect(tram.otherEnd == "Schwadorf, Brühl (Rheinland)")
        #expect(tram.time.delayMinutes == 2)
        #expect(RISJourneysClient.isJourneyId(tram.tripId))
    }

    @Test func onlyTheProductsAsked() async throws {
        let (db, session) = provider()
        defer { session.invalidateAndCancel() }
        let entries = try await db.board(.departures, at: koeln, date: noon, duration: 60, products: [.highSpeed])
        #expect(entries.map(\.line.name) == ["ICE 22"])
        // No buses or trams asked: RIS::Boards isn't asked either.
        #expect(DBBoardProtocol.requests.withLock { $0 }.allSatisfy { !$0.contains("ris-boards") })
    }

    /// A stop IRIS doesn't know (a bus stop, a station abroad): everything from RIS::Boards, trains included.
    @Test func aStopIRISDoesntKnowComesFromRISBoards() async throws {
        let (db, session) = provider(irisKnowsStation: false)
        defer { session.invalidateAndCancel() }
        let entries = try await db.board(.departures, at: koeln, date: noon, duration: 60, products: Set(Product.allCases))
        #expect(entries.map(\.line.name) == ["STR 18"])
        let board = try #require(DBBoardProtocol.requests.withLock { $0 }.first { $0.contains("ris-boards") })
        #expect(board.contains("HIGH_SPEED_TRAIN"))
        #expect(board.contains("%2B01:00"))
    }

    @Test func nothingFromDBThrows() async throws {
        let (db, session) = provider(irisKnowsStation: false, risAnswers: false)
        defer { session.invalidateAndCancel() }
        await #expect(throws: TransitError.self) {
            try await db.board(.departures, at: koeln, date: noon, duration: 60, products: Set(Product.allCases))
        }
    }

    /// `CombinedProvider` takes DB's board and only asks Transitous when DB has nothing.
    @Test func combinedProviderAsksDBFirst() async throws {
        let (db, session) = provider()
        defer { session.invalidateAndCancel() }
        let http = HTTPClient(session: session)
        let combined = CombinedProvider(primary: TransitousProvider(http: http), bahnDe: nil, bahnExpert: nil, vagonweb: nil,
                                        bahnJetzt: nil, dbBoards: db)
        let entries = try await combined.board(.departures, at: koeln, date: noon, duration: 60, products: Set(Product.allCases))
        #expect(entries.first?.source == .bahnDe)
        #expect(DBBoardProtocol.requests.withLock { $0 }.allSatisfy { !$0.contains("transitous") })

        let (empty, emptySession) = provider(irisKnowsStation: false, risAnswers: false)
        defer { emptySession.invalidateAndCancel() }
        let fallback = CombinedProvider(primary: TransitousProvider(http: HTTPClient(session: emptySession)), bahnDe: nil, bahnExpert: nil,
                                        vagonweb: nil, bahnJetzt: nil, dbBoards: empty)
        _ = try? await fallback.board(.departures, at: koeln, date: noon, duration: 60, products: Set(Product.allCases))
        #expect(DBBoardProtocol.requests.withLock { $0 }.contains { $0.contains("transitous") })
    }

    /// A train from IRIS opens its trip from RIS::Journeys: the run of that number calling there at that time.
    @Test func irisTrainOpensItsTripFromRISJourneys() async throws {
        let (_, session) = provider()
        defer { session.invalidateAndCancel() }
        let http = HTTPClient(session: session)
        let ris = RISRoutingProvider(http: http, bahnDe: BahnDeClient(http: http, gate: BahnDeGate()),
                                     journeyDetails: RISJourneysClient(serverURL: URL(string: "https://proxy.test")!, http: http))
        // ICE 7 leaves Hamburg Dammtor at 12:21 on 3 Nov 2026 (the fixture).
        let planned = try #require(JSONDecoding.parseISODate("2026-11-03T12:21:00+01:00"))
        let reference = IRISTripReference(category: "ICE", number: "7", eva: "8002548", planned: planned, kind: .departures)
        let trip = try await ris.trip(id: reference.id)
        #expect(trip.id == "20261103-c5ed6631-9860-3f62-aa16-50637daedbaf")
        #expect(trip.source == .bahnDe)
        #expect(trip.line?.name == "ICE 7")
        #expect(trip.stopovers.first?.station.name == "Hamburg Dammtor")
        #expect(trip.stopovers.first?.arrival == nil)
        #expect(trip.stopovers[1].arrival != nil && trip.stopovers[1].departure != nil)
        #expect(trip.stopovers[1].departurePlatform?.best == "14")
        #expect(trip.stopovers.last?.station.name == "Basel SBB")
    }

    /// Without RIS::Boards (no key on our server), the trains still come from IRIS and the asked buses and trams
    /// are left to Transitous.
    @Test func withoutRISBoardsBusesAreLeftToTransitous() async throws {
        let (db, session) = provider(risAnswers: false)
        defer { session.invalidateAndCancel() }
        let result = try await db.boardResult(.departures, at: koeln, date: noon, duration: 60, products: Set(Product.allCases))
        #expect(result.entries.allSatisfy { $0.line.product.isTrain })
        #expect(result.missing.contains(.bus) && result.missing.contains(.tram))
        let trainsOnly = try await db.boardResult(.departures, at: koeln, date: noon, duration: 60, products: [.highSpeed])
        #expect(trainsOnly.missing.isEmpty)
    }

    /// IRIS answers, RIS::Boards doesn't: the trains stay DB's and the bus comes from Transitous.
    @Test func combinedProviderFillsBusesFromTransitousWhenRISBoardsFails() async throws {
        let (db, session) = provider(risAnswers: false)
        defer { session.invalidateAndCancel() }
        let combined = CombinedProvider(primary: BusOnlyProvider(station: koeln, at: noon.addingTimeInterval(600)), bahnDe: nil,
                                        bahnExpert: nil, vagonweb: nil, bahnJetzt: nil, dbBoards: db)
        let entries = try await combined.board(.departures, at: koeln, date: noon, duration: 60, products: Set(Product.allCases))
        #expect(entries.contains { $0.line.name == "ICE 22" && $0.source == .bahnDe })
        #expect(entries.contains { $0.line.name == "Bus 133" && $0.source == .transitous })
        #expect(!entries.contains { $0.line.name == "ICE 999" })
        #expect(entries.map(\.time.planned) == entries.map(\.time.planned).sorted())
    }

    @Test func tripReferenceRoundTrips() throws {
        let reference = IRISTripReference(category: "ICE", number: "22", eva: "8000207", planned: noon, kind: .arrivals)
        #expect(IRISTripReference(id: reference.id) == reference)
        #expect(IRISTripReference(id: "2|#VN#1#ST#") == nil)
    }
}

/// Transitous as a stand-in: one bus and one train at `station` (the train must not be taken over).
private struct BusOnlyProvider: TransitProvider {
    let station: Station
    let at: Date
    var source: DataSource { .transitous }
    func searchStations(_ query: String) async throws -> [Station] { [] }
    func journeys(_ query: JourneyQuery) async throws -> JourneyPage { throw TransitError.notFound("") }
    func trip(id: String) async throws -> Trip { throw TransitError.notFound(id) }
    func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] {
        [("Bus 133", Product.bus), ("ICE 999", Product.highSpeed)].map { name, product in
            BoardEntry(kind: kind, tripId: name, station: station, line: Line(name: name, number: nil, product: product, operatorName: nil),
                       otherEnd: "Somewhere", time: TimeInfo(planned: at, actual: nil), platform: PlatformInfo(planned: nil, actual: nil),
                       cancelled: false, terminatesOrOriginatesHere: nil, remarks: [], source: .transitous)
        }
    }
}

/// DB Timetables (plan, fchg, station) through the Worker's address, RIS::Boards through our server.
private final class DBBoardProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    static let irisKnowsStation = Mutex(true)
    static let risAnswers = Mutex(true)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.withLock { $0.append(url.absoluteString) }
        var status = 404
        var body = Data()
        func fixture(_ name: String, _ ext: String) -> Data {
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures").flatMap { try? Data(contentsOf: $0) } ?? Data()
        }
        let path = url.path()
        if path.contains("/timetables/v1/"), Self.irisKnowsStation.withLock({ $0 }) {
            status = 200
            if path.contains("/plan/8000207/261104/12") {
                body = fixture("iris-plan-koeln", "xml")
            } else if path.hasSuffix("/fchg/8000207") {
                body = fixture("iris-fchg-koeln", "xml")
            } else {
                body = Data("<timetable/>".utf8)
            }
        } else if path.hasSuffix("/ris-journeys/v2/find") {
            status = 200
            body = Data(#"{"journeys": [{"journeyID": "20261103-c5ed6631-9860-3f62-aa16-50637daedbaf", "info": {"transportAtStart": {"category": "ICE", "journeyNumber": 7}}}]}"#.utf8)
        } else if path.contains("/ris-journeys/v2/") {
            status = 200
            body = fixture("ris-journeys-details-ice7", "json")
        } else if path.contains("/ris-boards/"), Self.risAnswers.withLock({ $0 }) {
            status = 200
            body = fixture("ris-boards-departures-koeln", "json")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
