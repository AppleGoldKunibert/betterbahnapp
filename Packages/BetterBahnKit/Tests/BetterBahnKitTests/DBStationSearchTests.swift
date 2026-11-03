import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// Station search at bahn.de first (as in the DB Navigator), Transitous for what bahn.de doesn't find and for
/// the searches it has its own logic for.
@Suite(.serialized) struct DBStationSearchTests {
    static let hits = #"""
    [{"extId": "8000096", "name": "Stuttgart Hbf", "lat": 48.784, "lon": 9.182, "type": "ST", "products": ["ICE", "EC_IC", "REGIONAL", "SBAHN", "BUS"]},
     {"extId": "8005773", "name": "Stuttgart Stadtmitte", "lat": 48.776, "lon": 9.172, "type": "ST", "products": ["SBAHN"]},
     {"extId": "561473", "name": "Charlottenplatz, Stuttgart", "lat": 48.776, "lon": 9.182, "type": "ST", "products": ["TRAM", "UBAHN"]},
     {"extId": "123456", "name": "Stuttgart Busbahnhof", "lat": 48.70, "lon": 9.19, "type": "ST", "products": ["BUS"]},
     {"name": "Stuttgart, Königstraße 1", "type": "ADR"}]
    """#

    func provider(bahnDeHits: String = hits) -> (CombinedProvider, URLSession) {
        StationSearchProtocol.requests.withLock { $0 = [] }
        StationSearchProtocol.bahnDeHits.withLock { $0 = bahnDeHits }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StationSearchProtocol.self]
        let session = URLSession(configuration: config)
        let http = HTTPClient(session: session)
        return (CombinedProvider(primary: TransitousProvider(http: http), bahnDe: BahnDeClient(http: http, gate: BahnDeGate()),
                                 bahnExpert: nil, vagonweb: nil, bahnJetzt: nil, stationsFromDB: true), session)
    }

    var askedTransitous: Bool { StationSearchProtocol.requests.withLock { $0 }.contains { $0.contains("transitous") } }

    /// bahn.de's stations in its order; the bus-only stop and the address left out; Transitous not asked.
    @Test func bahnDeFirst() async throws {
        let (combined, session) = provider()
        defer { session.invalidateAndCancel() }
        let stations = try await combined.searchStations(StationSearch(parsing: "Stuttgart"), near: nil)
        #expect(stations.map(\.name) == ["Stuttgart Hbf", "Stuttgart Stadtmitte", "Charlottenplatz, Stuttgart"])
        #expect(stations.allSatisfy { $0.source == .bahnDe && $0.evaNumber == $0.id })
        #expect(!askedTransitous)
    }

    @Test func modeShortcutsGoByBahnDesProducts() async throws {
        let (combined, session) = provider()
        defer { session.invalidateAndCancel() }
        let buses = try await combined.searchStations(StationSearch(parsing: "b Stuttgart"), near: nil)
        #expect(buses.map(\.name) == ["Stuttgart Hbf", "Stuttgart Busbahnhof"])
        let trams = try await combined.searchStations(StationSearch(parsing: "t Stuttgart"), near: nil)
        #expect(trams.map(\.name) == ["Charlottenplatz, Stuttgart"])
    }

    /// "l": nearest first, sorted on the device (the location isn't sent).
    @Test func nearestFirstOnTheDevice() async throws {
        let (combined, session) = provider()
        defer { session.invalidateAndCancel() }
        let near = Coordinate(latitude: 48.776, longitude: 9.181)
        let stations = try await combined.searchStations(StationSearch(parsing: "l Stuttgart"), near: near)
        #expect(stations.first?.name == "Charlottenplatz, Stuttgart")
        #expect(StationSearchProtocol.requests.withLock { $0 }.allSatisfy { !$0.contains("48.77") })
    }

    @Test func transitousForWhatBahnDeDoesntFind() async throws {
        let (combined, session) = provider(bahnDeHits: "[]")
        defer { session.invalidateAndCancel() }
        _ = try? await combined.searchStations(StationSearch(parsing: "Nirgendwo"), near: nil)
        #expect(askedTransitous)
    }

    @Test func searchesWithTransitousOwnLogicStayThere() {
        #expect(!CombinedProvider.asksDBFirst(StationSearch(parsing: "Hbf")))
        #expect(!CombinedProvider.asksDBFirst(StationSearch(parsing: "bahnhof")))
        #expect(!CombinedProvider.asksDBFirst(StationSearch(parsing: "Po")))
        #expect(!CombinedProvider.asksDBFirst(StationSearch(parsing: "FF")))
        #expect(CombinedProvider.asksDBFirst(StationSearch(parsing: "Köln Hbf")))
        #expect(CombinedProvider.asksDBFirst(StationSearch(parsing: "Charlottenplatz")))
    }
}

/// bahn.de's search (through the Worker's address in tests) answers `bahnDeHits`; Transitous 503.
private final class StationSearchProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    static let bahnDeHits = Mutex("[]")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.withLock { $0.append(url.absoluteString) }
        var status = 503
        var body = Data()
        if url.path().hasSuffix("reiseloesung/orte") {
            status = 200
            body = Data(Self.bahnDeHits.withLock { $0 }.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
