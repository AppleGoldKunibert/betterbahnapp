import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

@Suite struct DBShareTests {
    private let webText = """
        Verbindung am Sa. 26.09.2026
        • von Stuttgart Hbf, Abfahrt 16:57 Uhr Gl. 16 mit 89687
        • nach Berlin Hbf, Ankunft 22:22 Uhr Gl. 5 mit ICE 1502
        Verbindung ansehen: https://www.bahn.de/buchung/start?vbid=1cea41f0-5a87-4d9f-8456-305c9d635d36
        """

    private let navigatorText = """
        Schaffhausen → Berlin Hbf
        27.09.2026

        IC 488
        Nach Stuttgart Hbf
        Ab 12:16 Schaffhausen, Gleis 4
        An 14:43 Stuttgart Hbf, Gleis 3

        ICE 576
        Nach Hamburg Hbf
        Ab 15:23 Stuttgart Hbf, Gleis 6
        An 16:40 Frankfurt(Main)Hbf, Gleis 8

        ICE 834
        Nach Berlin Gesundbrunnen
        Ab 17:02 Frankfurt(Main)Hbf, Gleis 13
        An 20:54 Berlin Hbf, Gleis 6

        Verbindung ansehen:
        https://www.bahn.de/buchung/start?vbid=aaae3fa2%2D4333%2D4b83%2D9a0f%2D7b01fe3bd5d4
        """

    private func berlin(_ string: String) -> Date {
        var components = DateComponents()
        let parts = string.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        (components.year, components.month, components.day, components.hour, components.minute) =
            (parts[0], parts[1], parts[2], parts[3], parts[4])
        return DBShare.berlinCalendar.date(from: components)!
    }

    @Test func findsVbidInBothFormats() {
        #expect(DBShare.vbid(in: webText) == "1cea41f0-5a87-4d9f-8456-305c9d635d36")
        #expect(DBShare.vbid(in: navigatorText) == "aaae3fa2-4333-4b83-9a0f-7b01fe3bd5d4")
        #expect(DBShare.vbid(in: "https://www.bahn.de/buchung/start?vbid=nonsense") == nil)
    }

    @Test func parsesWebText() throws {
        let connection = try #require(DBShare.connection(fromText: webText))
        #expect(connection.origin.name == "Stuttgart Hbf")
        #expect(connection.destination.name == "Berlin Hbf")
        #expect(connection.departure == berlin("2026-09-26 16:57"))
        #expect(connection.arrival == berlin("2026-09-26 22:22"))
        #expect(connection.legs.isEmpty)
        #expect(connection.firstTrain == "89687")
        #expect(connection.lastTrain == "ICE 1502")
    }

    @Test func parsesNavigatorText() throws {
        let connection = try #require(DBShare.connection(fromText: navigatorText))
        #expect(connection.legs.map(\.trainName) == ["IC 488", "ICE 576", "ICE 834"])
        #expect(connection.legs.map(\.origin.name) == ["Schaffhausen", "Stuttgart Hbf", "Frankfurt(Main)Hbf"])
        #expect(connection.legs.map(\.destination.name) == ["Stuttgart Hbf", "Frankfurt(Main)Hbf", "Berlin Hbf"])
        #expect(connection.departure == berlin("2026-09-27 12:16"))
        #expect(connection.arrival == berlin("2026-09-27 20:54"))
    }

    @Test func navigatorTimesRollOverMidnight() throws {
        let text = """
            München Hbf → Berlin Hbf
            27.09.2026

            ICE 1000
            Nach Berlin Hbf
            Ab 23:10 München Hbf, Gleis 1
            An 04:05 Berlin Hbf, Gleis 2
            """
        let connection = try #require(DBShare.connection(fromText: text))
        #expect(connection.arrival == berlin("2026-09-28 04:05"))
    }

    @Test func rejectsOtherText() {
        #expect(!DBShare.isConnection("Schau mal: https://www.bahn.de/"))
        #expect(!DBShare.isConnection("Treffen am 27.09.2026 um 12:00"))
        #expect(DBShare.isConnection(webText))
        #expect(DBShare.isConnection(navigatorText))
    }

    @Test func parsesRecon() throws {
        let recon = "¶HKI¶T$A=1@O=Stuttgart Hbf@X=9182760@Y=48784782@L=8000096@a=128@$A=1@O=Nürnberg Hbf@X=11082989@Y=49445615@L=8000284@a=128@$202609261657$202609261921$            89687$$1$$$$$$§T$A=1@O=Nürnberg Hbf@X=11082989@Y=49445615@L=8000284@a=128@$A=1@O=Berlin Hbf@X=13369549@Y=52525589@L=8098160@a=128@$202609261936$202609262222$ICE          1502$$1$$$$$$¶KC¶#VE#2#"
        let legs = try #require(DBShare.legs(fromRecon: recon))
        #expect(legs.map(\.trainName) == ["89687", "ICE 1502"])
        #expect(legs[0].origin.evaNumber == "8000096")
        #expect(legs[0].destination.name == "Nürnberg Hbf")
        #expect(abs((legs[1].destination.coordinate?.latitude ?? 0) - 52.525589) < 0.000_001)
        #expect(legs[0].departure == berlin("2026-09-26 16:57"))
        #expect(legs[1].arrival == berlin("2026-09-26 22:22"))
    }

    @Test func appURLRoundTrips() throws {
        let url = try #require(DBShare.appURL(for: navigatorText))
        #expect(DBShare.text(fromAppURL: url) == navigatorText)
        #expect(DBShare.text(fromAppURL: URL(string: "betterbahn://share?data=abc")!) == nil)
    }

    /// Issue #578: RJ 179 Hamburg → Berlin on 13.12.2026, the first day of a timetable year Transitous didn't
    /// have DB's data for yet. bahn.de's board and journey details give the leg instead.
    @Test func buildsLegFromBahnDeWhenTimetableLacksTrain() throws {
        let recon = "¶HKI¶T$A=1@O=Hamburg Hbf@X=10006909@Y=53552733@L=8002549@a=128@$A=1@O=Berlin Hbf@X=13369549@Y=52525589@L=8098160@a=128@$202612131734$202612131921$RJ            179$$1$$$$$$¶KC¶"
        let shared = try #require(DBShare.legs(fromRecon: recon)?.first)
        let board = try fixture("bahnde-board-hamburg-rj179", as: BahnDeClient.Board.self)
        let entry = try #require(BahnDeClient.boardEntry(in: board, for: shared))
        #expect(entry.verkehrmittel?.name == "RJ 179")
        let details = try fixture("bahnde-fahrt-rj179", as: BahnDeClient.JourneyDetails.self)
        let leg = try #require(BahnDeClient.leg(shared, entry: entry, details: details))
        #expect(leg.tripId == nil)
        #expect(leg.line?.name == "RJ 179")
        #expect(leg.line?.product == .highSpeed)
        #expect(leg.direction == "Praha hl.n.")
        #expect(leg.departure.planned == berlin("2026-12-13 17:34"))
        #expect(leg.arrival.planned == berlin("2026-12-13 19:21"))
        #expect(leg.stopovers.map(\.station.name) == ["Hamburg Hbf", "Berlin-Spandau", "Berlin Hbf"])
        #expect(leg.arrivalPlatform?.planned == "3")
        #expect(leg.destination.evaNumber == "8098160")
    }

    @Test func boardEntryNeedsSameTimeAndTrain() throws {
        let board = try fixture("bahnde-board-hamburg-rj179", as: BahnDeClient.Board.self)
        let station = Station(id: "8002549", name: "Hamburg Hbf", coordinate: nil, evaNumber: "8002549", source: .bahnDe)
        func shared(_ name: String, _ time: String) -> SharedConnection.Leg {
            .init(trainName: name, origin: station, destination: station, departure: berlin(time), arrival: berlin(time))
        }
        #expect(BahnDeClient.boardEntry(in: board, for: shared("RJ 179", "2026-12-13 17:35")) == nil)
        #expect(BahnDeClient.boardEntry(in: board, for: shared("RJ 177", "2026-12-13 17:34")) == nil)
        // A bare run number, as bahn.de's text names some regional trains.
        #expect(BahnDeClient.boardEntry(in: board, for: shared("81633", "2026-12-13 17:33"))?.verkehrmittel?.mittelText == "RB31")
    }

    @Test func plainLegNeedsLocatedStations() throws {
        let malmo = Station(id: "7400004", name: "Malmö Central", coordinate: Coordinate(latitude: 55.609231, longitude: 13.00126),
                            evaNumber: "7400004", source: .bahnDe)
        let copenhagen = Station(id: "8601309", name: "Koebenhavn H", coordinate: Coordinate(latitude: 55.673063, longitude: 12.565562),
                                 evaNumber: "8601309", source: .bahnDe)
        let shared = SharedConnection.Leg(trainName: "R 1059", origin: malmo, destination: copenhagen,
                                          departure: berlin("2026-12-13 11:20"), arrival: berlin("2026-12-13 11:58"))
        let leg = try #require(DBShareImporter.plainLeg(shared))
        #expect(leg.line?.name == "R 1059")
        #expect(leg.line?.number == "1059")
        #expect(leg.line?.product == .regional)
        #expect(leg.savedTrip?.stopovers.count == 2)
        var unknown = shared
        unknown.destination.coordinate = nil
        #expect(DBShareImporter.plainLeg(unknown) == nil)
    }

    @Test func lineProductFromNameAndGattung() {
        #expect(DBShareImporter.line(named: "ECE 393").product == .highSpeed)
        #expect(DBShareImporter.line(named: "IC 488").product == .longDistance)
        #expect(DBShareImporter.line(named: "RE 80", gattung: "REGIONAL").product == .regionalExpress)
        #expect(DBShareImporter.line(named: "NJ 491", gattung: "EC_IC").product == .nightTrain)
        #expect(DBShareImporter.line(named: "Bus 100", gattung: "BUS").product == .bus)
    }

    @Test func bareTrainNumberMatchesRunNumber() {
        let line = Line(name: "RE 8", number: "8", product: .regionalExpress, operatorName: nil, tripNumber: "89687")
        #expect(DBShareImporter.matches("89687", line))
        #expect(DBShareImporter.matches("ICE 1502", Line(name: "ICE 1502", number: "1502", product: .highSpeed, operatorName: nil)))
        #expect(!DBShareImporter.matches("ICE 1502", Line(name: "ICE 1503", number: "1503", product: .highSpeed, operatorName: nil)))
    }
}

/// The importer's order for a train the search doesn't find (#578): Transitous' board, then bahn.de's own
/// timetable, then the share itself. Getting no answer at all is an error rather than a poorer train.
@Suite struct DBShareImporterFallbackTests {
    private let recon = "¶HKI¶T$A=1@O=Hamburg Hbf@X=10006909@Y=53552733@L=8002549@a=128@$A=1@O=Berlin Hbf@X=13369549@Y=52525589@L=8098160@a=128@$202612131734$202612131921$RJ            179$$1$$$$$$¶KC¶"

    private func sharedConnection() throws -> SharedConnection {
        let legs = try #require(DBShare.legs(fromRecon: recon))
        return SharedConnection(origin: legs[0].origin, destination: legs[0].destination, departure: legs[0].departure,
                                arrival: legs[0].arrival, legs: legs, firstTrain: legs[0].trainName, lastTrain: legs[0].trainName)
    }

    /// Transitous (the mock) knows no train at all; bahn.de's answers come from `protocolClass`.
    private func makeImporter(bahnDe protocolClass: AnyClass, provider: MockProvider = MockProvider(source: .transitous))
        -> (DBShareImporter, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        let combined = CombinedProvider(primary: provider, fallback: nil, bahnDe: nil, bahnExpert: nil, vagonweb: nil, bahnJetzt: nil)
        let bahnDe = BahnDeClient(http: HTTPClient(session: session), gate: BahnDeGate())
        return (DBShareImporter(provider: combined, bahnDe: bahnDe), session)
    }

    @Test func takesTrainTransitousLacksFromBahnDe() async throws {
        let (importer, session) = makeImporter(bahnDe: SharedLegBahnDeProtocol.self)
        defer { session.invalidateAndCancel() }
        let journey = try await importer.journey(from: sharedConnection())
        #expect(journey.legs.count == 1)
        #expect(journey.legs[0].stopovers.map(\.station.name) == ["Hamburg Hbf", "Berlin-Spandau", "Berlin Hbf"])
        #expect(journey.legs[0].arrivalPlatform?.planned == "3")
    }

    @Test func takesTrainAsSharedWhenBahnDeDoesNotListIt() async throws {
        let (importer, session) = makeImporter(bahnDe: EmptyBoardBahnDeProtocol.self)
        defer { session.invalidateAndCancel() }
        let journey = try await importer.journey(from: sharedConnection())
        #expect(journey.legs.count == 1)
        #expect(journey.legs[0].line?.name == "RJ 179")
        #expect(journey.legs[0].stopovers.isEmpty)
        #expect(journey.legs[0].tripId == nil)
    }

    @Test func noAnswerIsAnErrorNotAPoorerTrain() async throws {
        let provider = MockProvider(source: .transitous)
        provider.failing = true
        let (importer, session) = makeImporter(bahnDe: UnreachedBahnDeProtocol.self, provider: provider)
        defer { session.invalidateAndCancel() }
        let connection = try sharedConnection()
        await #expect(throws: DBShareError.unreadable) { try await importer.journey(from: connection) }
        #expect(UnreachedBahnDeProtocol.requests.withLock { $0 } == 0)
    }

    @Test func toldUnknownFromUnavailable() {
        #expect(DBShareImporter.isUnavailable(URLError(.notConnectedToInternet)))
        #expect(DBShareImporter.isUnavailable(CancellationError()))
        #expect(DBShareImporter.isUnavailable(TransitError.timeout))
        #expect(DBShareImporter.isUnavailable(TransitError.http(status: 503, body: nil)))
        #expect(DBShareImporter.isUnavailable(TransitError.http(status: 452, body: nil)))
        #expect(!DBShareImporter.isUnavailable(TransitError.http(status: 404, body: nil)))
        #expect(!DBShareImporter.isUnavailable(TransitError.notFound("Fahrt")))
        #expect(!DBShareImporter.isUnavailable(TransitError.decoding("Board")))
    }
}

/// bahn.de with RJ 179 on Hamburg Hbf's board on 13.12.2026 and its journey details.
private final class SharedLegBahnDeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let fixture = path.hasSuffix("reiseloesung/abfahrten") ? "bahnde-board-hamburg-rj179"
            : path.hasSuffix("reiseloesung/fahrt") ? "bahnde-fahrt-rj179" : nil
        let body = fixture.flatMap { Bundle.module.url(forResource: $0, withExtension: "json", subdirectory: "Fixtures") }
            .flatMap { try? Data(contentsOf: $0) } ?? Data("{}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// bahn.de whose boards list no train.
private final class EmptyBoardBahnDeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"entries":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// bahn.de that must not be asked: counts the requests.
private final class UnreachedBahnDeProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
}
