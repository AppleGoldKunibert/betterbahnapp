import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// DB's own routing (RIS::Routing) as the fallback for Transitous' journeys.
@Suite(.serialized) struct RISRoutingTests {
    let berlin = Station(id: "8011160", name: "Berlin Hbf", coordinate: nil, evaNumber: "8011160", source: .bahnDe)
    let munich = Station(id: "8000261", name: "München Hbf", coordinate: nil, evaNumber: "8000261", source: .bahnDe)

    func page() throws -> JourneyPage {
        RISRoutingProvider.page(from: try fixture("ris-routing-multimodal", as: RISRoutingProvider.Response.self))
    }

    func date(_ iso: String) throws -> Date { try #require(JSONDecoding.parseISODate(iso)) }

    @Test func requestAsksForDepartureOrArrivalWithTheQuerysLimits() throws {
        let departure = try date("2026-11-04T07:00:00Z")
        let plain = RISRoutingProvider.requestBody(JourneyQuery(from: berlin, to: munich, date: departure), from: "8011160", to: "8000261")
        #expect(plain["departureTime"] as? String == "2026-11-04T07:00:00.000Z")
        #expect(plain["arrivalTime"] == nil)
        #expect(plain["maxChanges"] as? Int == 5)
        #expect(plain["navigationContext"] as? String == "")
        #expect(plain["filterTransports"] == nil)
        #expect((plain["origin"] as? [String: String])?["evaNumber"] == "8011160")

        let limited = RISRoutingProvider.requestBody(
            JourneyQuery(from: berlin, to: munich, date: departure, isArrival: true, cursor: "3|OF|later",
                         products: [.highSpeed, .longDistance, .nightTrain], maxTransfers: 1),
            from: "8011160", to: "8000261")
        #expect(limited["arrivalTime"] as? String == "2026-11-04T07:00:00.000Z")
        #expect(limited["departureTime"] == nil)
        #expect(limited["maxChanges"] as? Int == 1)
        #expect(limited["navigationContext"] as? String == "3|OF|later")
        #expect(limited["filterTransports"] as? [String] == ["HIGH_SPEED_TRAIN", "INTERCITY_TRAIN"])
    }

    /// An ICE straight through: named, numbered and with platforms as DB has them; "Hält nur zum Einsteigen"
    /// marks the stop, and a plan without live data ("SCHEDULE") has no live time.
    @Test func longDistanceTrainWithItsStops() throws {
        let page = try page()
        #expect(page.source == .bahnDe)
        #expect(page.earlierCursor == "3|OB|earlier")
        #expect(page.laterCursor == "3|OF|later")
        #expect(page.journeys.count == 3)

        let journey = page.journeys[0]
        #expect(journey.source == .bahnDe)
        let leg = try #require(journey.legs.first)
        #expect(journey.legs.count == 1)
        #expect(leg.line?.name == "ICE 1005")
        #expect(leg.line?.number == "1005")
        #expect(leg.line?.product == .highSpeed)
        #expect(leg.line?.operatorName == "DB Fernverkehr AG")
        #expect(leg.direction == "München Hbf")
        #expect(leg.tripId?.hasPrefix("2|#VN#1#ST#") == true)
        #expect(leg.origin.id == "8098160")
        #expect(leg.origin.evaNumber == "8098160")
        #expect(leg.origin.source == .bahnDe)
        let origin = try #require(leg.origin.coordinate)
        #expect(abs(origin.latitude - 52.525589) < 0.000_01 && abs(origin.longitude - 13.369549) < 0.000_01)
        #expect(leg.departure.planned == (try date("2026-11-04T07:36:00Z")))
        #expect(leg.departure.actual == nil)
        #expect(leg.departurePlatform?.planned == "4")
        #expect(leg.arrivalPlatform?.planned == "23")
        #expect(leg.stopovers.map(\.station.name) == ["Berlin Hbf", "Berlin Südkreuz", "Halle(Saale)Hbf", "Erfurt Hbf", "München Hbf"])
        #expect(leg.stopovers[1].access == .entryOnly)
        #expect(leg.stopovers[1].arrivalPlatform?.planned == "5")
    }

    /// A regional train, a walk between Frankfurt Airport's two stations and a late ICE.
    @Test func regionalTrainWalkAndLiveTimes() throws {
        let journey = try page().journeys[1]
        #expect(journey.legs.map(\.isWalking) == [false, true, false])
        #expect(journey.transfers == 1)

        let regional = journey.legs[0]
        #expect(regional.line?.name == "RE2 (29542)")
        #expect(regional.line?.number == "29542")
        #expect(regional.line?.tripNumber == "29542")
        #expect(regional.line?.product == .regionalExpress)
        #expect(regional.line?.operatorName == "vlexx")

        let walk = journey.legs[1]
        #expect(walk.origin == regional.destination)
        #expect(walk.destination.name == "Frankfurt(M) Flughafen Fernbf")
        #expect(walk.destination.coordinate != nil)
        #expect(walk.departure.planned == (try date("2026-11-03T15:35:00Z")))
        #expect(walk.arrival.planned == (try date("2026-11-03T15:50:00Z")))

        let ice = journey.legs[2]
        #expect(ice.line?.name == "ICE 611")
        #expect(ice.departure.planned == (try date("2026-11-03T15:51:00Z")))
        #expect(ice.departure.delayMinutes == 33)
        #expect(ice.departurePlatform?.best == "Fern 5")
    }

    /// An S-Bahn is named by its line, with the run as trip number, as Transitous does.
    @Test func suburbanTrainIsNamedByItsLine() throws {
        let leg = try #require(try page().journeys[2].transitLegs.first)
        #expect(leg.line?.name == "S5")
        #expect(leg.line?.number == "5")
        #expect(leg.line?.tripNumber == "5101")
        #expect(leg.line?.product == .suburban)
        #expect(leg.departure.actual != nil)
    }

    @Test func productsFromTypeAndCategory() {
        #expect(RISRoutingProvider.product(type: "INTERCITY_TRAIN", category: "NJ", name: "NJ 295") == .nightTrain)
        #expect(RISRoutingProvider.product(type: "INTERCITY_TRAIN", category: "EC", name: "EC 213") == .longDistance)
        #expect(RISRoutingProvider.product(type: "REGIONAL_TRAIN", category: "DB", name: "RB45 (29332)") == .regional)
        #expect(RISRoutingProvider.product(type: "BUS", category: "Bus", name: "Bus X35") == .bus)
        // bahn.de's journey details only have the category.
        #expect(RISRoutingProvider.product(type: nil, category: "RJ", name: "RJ 383") == .longDistance)
        #expect(RISRoutingProvider.product(type: nil, category: "ICE", name: "ICE 101") == .highSpeed)
    }

    /// The trip of a leg found by RIS comes from bahn.de's journey details: its ID is bahn.de's journey ID.
    @Test func tripFromBahnDeJourneyDetails() throws {
        let details = try fixture("bahnde-fahrt-ice101", as: BahnDeClient.JourneyDetails.self)
        let trip = RISRoutingProvider.trip(id: "2|#VN#1#ST#test", from: details)
        #expect(trip.id == "2|#VN#1#ST#test")
        #expect(trip.source == .bahnDe)
        #expect(trip.line?.name == details.zugName)
        #expect(trip.line?.product == .highSpeed)
        #expect(trip.stopovers.count == details.halte.count)
        #expect(trip.stopovers.allSatisfy { $0.station.source == .bahnDe && $0.station.id == $0.station.evaNumber })
        #expect(trip.stopovers.first?.departure != nil)
        #expect(trip.stopovers.last?.arrival != nil)
    }

    /// When Transitous fails, the journeys come from RIS, and its next page from RIS again.
    @Test func combinedProviderFallsBackToRIS() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RISFallbackProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        RISFallbackProtocol.requests.withLock { $0 = [] }
        let http = HTTPClient(session: session)
        let ris = RISRoutingProvider(http: http, bahnDe: BahnDeClient(http: http, gate: BahnDeGate()))
        let combined = CombinedProvider(primary: TransitousProvider(http: http), fallback: ris,
                                        bahnDe: nil, bahnExpert: nil, vagonweb: nil, bahnJetzt: nil)

        let page = try await combined.journeys(JourneyQuery(from: berlin, to: munich, date: try date("2026-11-04T07:00:00Z")))
        #expect(page.source == .bahnDe)
        #expect(page.journeys.first?.legs.first?.line?.name == "ICE 1005")
        #expect(page.laterCursor == "bahnDe:3|OF|later")
        #expect(RISFallbackProtocol.requests.withLock { $0.contains { $0.contains("verkehrslage.bahnhof.de") } })

        RISFallbackProtocol.requests.withLock { $0 = [] }
        var next = JourneyQuery(from: berlin, to: munich, date: try date("2026-11-04T07:00:00Z"))
        next.cursor = page.laterCursor
        let later = try await combined.journeys(next)
        #expect(later.source == .bahnDe)
        #expect(RISFallbackProtocol.requests.withLock { $0.allSatisfy { $0.contains("verkehrslage.bahnhof.de") } })
    }

    func dbFirst(risEmpty: Bool = false, bahnDeHits: String = "[]") -> (CombinedProvider, URLSession) {
        DBFirstProtocol.requests.withLock { $0 = [] }
        DBFirstProtocol.risEmpty.withLock { $0 = risEmpty }
        DBFirstProtocol.bahnDeHits.withLock { $0 = bahnDeHits }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DBFirstProtocol.self]
        let session = URLSession(configuration: config)
        let http = HTTPClient(session: session)
        let ris = RISRoutingProvider(http: http, bahnDe: BahnDeClient(http: http, gate: BahnDeGate()))
        return (CombinedProvider(primary: TransitousProvider(http: http), fallback: ris, bahnDe: nil, bahnExpert: nil,
                                 vagonweb: nil, bahnJetzt: nil, dbJourneys: ris), session)
    }

    /// DB is asked first; Transitous isn't asked when DB has journeys.
    @Test func journeysComeFromDBFirst() async throws {
        let (combined, session) = dbFirst()
        defer { session.invalidateAndCancel() }
        let page = try await combined.journeys(JourneyQuery(from: berlin, to: munich, date: try date("2026-11-04T07:00:00Z")))
        #expect(page.source == .bahnDe)
        #expect(page.journeys.first?.legs.first?.line?.name == "ICE 1005")
        #expect(DBFirstProtocol.requests.withLock { $0 }.allSatisfy { !$0.contains("transitous") })
    }

    /// When DB finds nothing (often abroad), Transitous is asked.
    @Test func transitousAnswersWhenDBFindsNothing() async throws {
        let (combined, session) = dbFirst(risEmpty: true)
        defer { session.invalidateAndCancel() }
        _ = try? await combined.journeys(JourneyQuery(from: berlin, to: munich, date: try date("2026-11-04T07:00:00Z")))
        let requests = DBFirstProtocol.requests.withLock { $0 }
        #expect(requests.contains { $0.contains("verkehrslage.bahnhof.de") })
        #expect(requests.contains { $0.contains("api.transitous.org") })
    }

    /// A stop without an EVA number goes to Transitous: bahn.de's nearest hit could be a railway station
    /// next to a bus stop, only a hit with the very same name counts.
    @Test func aStopWithoutEVAGoesToTransitous() async throws {
        let (combined, session) = dbFirst(bahnDeHits: #"[{"extId": "8000001", "name": "Somewhere Bahnhof", "type": "ST"}]"#)
        defer { session.invalidateAndCancel() }
        let busStop = Station(id: "de-DELFI_de:00000:99", name: "Somewhere Marktplatz", coordinate: nil, evaNumber: nil, source: .transitous)
        _ = try? await combined.journeys(JourneyQuery(from: busStop, to: munich, date: try date("2026-11-04T07:00:00Z")))
        let requests = DBFirstProtocol.requests.withLock { $0 }
        #expect(!requests.contains { $0.contains("verkehrslage.bahnhof.de") })
        #expect(requests.contains { $0.contains("api.transitous.org") })
    }

    @Test func aBahnDeHitWithTheSameNameIsTheStop() async throws {
        let (_, session) = dbFirst(bahnDeHits: #"[{"extId": "8000002", "name": "Somewhere Bahnhof", "type": "ST"}, {"extId": "123456", "name": "Somewhere Marktplatz", "type": "ST"}]"#)
        defer { session.invalidateAndCancel() }
        let http = HTTPClient(session: session)
        let ris = RISRoutingProvider(http: http, bahnDe: BahnDeClient(http: http, gate: BahnDeGate()))
        let busStop = Station(id: "de-DELFI_de:00000:99", name: "Somewhere Marktplatz", coordinate: nil, evaNumber: nil, source: .transitous)
        #expect(try await ris.eva(for: busStop) == "123456")
    }
}

/// Transitous answers 503 to everything; RIS::Routing the fixture (or no trips); bahn.de's search `bahnDeHits`.
private final class DBFirstProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    static let risEmpty = Mutex(false)
    static let bahnDeHits = Mutex("[]")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.withLock { $0.append(url.absoluteString) }
        var status = 503
        var body = Data()
        if url.host() == "verkehrslage.bahnhof.de" {
            status = 200
            if Self.risEmpty.withLock({ $0 }) {
                body = Data(#"{"trips": []}"#.utf8)
            } else if let fixture = Bundle.module.url(forResource: "ris-routing-multimodal", withExtension: "json", subdirectory: "Fixtures") {
                body = (try? Data(contentsOf: fixture)) ?? Data()
            }
        } else if url.path().hasSuffix("reiseloesung/orte") {
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

/// Transitous is down (503); RIS::Routing answers with the fixture.
private final class RISFallbackProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.withLock { $0.append(url.absoluteString) }
        var status = 503
        var body = Data()
        if url.host() == "verkehrslage.bahnhof.de",
           let fixture = Bundle.module.url(forResource: "ris-routing-multimodal", withExtension: "json", subdirectory: "Fixtures"),
           let data = try? Data(contentsOf: fixture) {
            status = 200
            body = data
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
