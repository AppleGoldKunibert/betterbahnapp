import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// RIS::Journeys through our server, asked before bahn.expert for a run by number and a run's stops.
@Suite(.serialized) struct RISJourneysTests {
    static let server = URL(string: "https://proxy.test")!

    func clients(risStatus: Int = 200) -> (BahnExpertClient, URLSession) {
        RISJourneysProtocol.risStatus.withLock { $0 = risStatus }
        RISJourneysProtocol.requests.withLock { $0 = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RISJourneysProtocol.self]
        let session = URLSession(configuration: config)
        let http = HTTPClient(session: session)
        let ris = RISJourneysClient(serverURL: Self.server, http: http)
        return (BahnExpertClient(http: http, ris: ris), session)
    }

    /// The day's runs only (RIS also lists yesterday's FLX 1243), the asked category first, then trains.
    @Test func findKeepsTheDaysRunsWithTheCategoryFirst() throws {
        let response = try fixture("ris-journeys-find-flx1243", as: RISJourneysClient.FindResponse.self)
        let data = try RISJourneysClient.expertFind(response, category: "FLX", day: "2026-11-03", limit: nil)
        let runs = try JSONDecoding.decoder.decode(BahnExpertClient.Envelope<[BahnExpertClient.FoundRun]>.self, from: data).json
        #expect(runs.count == 5)
        #expect(runs.allSatisfy { $0.journeyId.hasPrefix("20261103-") })
        let flx = try #require(runs.first)
        #expect(flx.train?.category == "FLX")
        #expect(flx.train?.journeyNumber == 1243)
        #expect(flx.train?.line == "10")
        #expect(flx.train?.transportType == "INTER_REGIONAL_TRAIN")
        #expect(flx.firstStop?.stopPlace.name == "Hamburg Hbf")
        #expect(flx.lastStop?.stopPlace.evaNumber == "8000096")

        let one = try RISJourneysClient.expertFind(response, category: nil, day: "2026-11-03", limit: 1)
        let first = try JSONDecoding.decoder.decode(BahnExpertClient.Envelope<[BahnExpertClient.FoundRun]>.self, from: one).json
        // Without a category, a train still comes before buses and trams.
        #expect(first.map(\.train?.category) == ["FLX"])
    }

    /// One stop per arrival and departure, with DB's plan, live time, platform and the stop's own ID.
    @Test func detailsInBahnExpertsShape() throws {
        let details = try fixture("ris-journeys-details-ice7", as: RISJourneysClient.Details.self)
        let id = "20261103-c5ed6631-9860-3f62-aa16-50637daedbaf"
        let data = try RISJourneysClient.expertDetails(details, journeyId: id)
        let run = try JSONDecoding.decoder.decode(BahnExpertClient.Envelope<BahnExpertClient.Details>.self, from: data).json
        #expect(run.train?.admin == "80")
        #expect(run.stops.map(\.stopPlace.evaNumber) == ["8002548", "8002549", "8000168", "8000152", "8000026", "8500010"])

        let platforms = try JSONDecoding.decoder.decode(BahnExpertClient.Envelope<BahnExpertClient.RunPlatforms>.self, from: data).json
        let hamburg = platforms.stops[1]
        #expect(hamburg.stopPlace.name == "Hamburg Hbf")
        #expect(hamburg.arrival?.scheduledPlatform == "14")
        #expect(hamburg.departure?.platform == "14")
        #expect(platforms.stops[0].arrival == nil)
        #expect(platforms.stops.last?.departure == nil)

        let times = try JSONDecoding.decoder.decode(BahnExpertClient.Envelope<BahnExpertClient.RunTimes>.self, from: data).json
        let arrival = try #require(times.stops[1].arrival)
        #expect(arrival.scheduledTime == JSONDecoding.parseISODate("2026-11-03T11:25:00Z"))
        #expect(arrival.time == JSONDecoding.parseISODate("2026-11-03T11:26:15Z"))

        let ids = try JSONDecoding.decoder.decode(BahnExpertClient.Envelope<BahnExpertClient.DetailsWithIDs>.self, from: data).json
        #expect(ids.stops[1].arrival?.id == "8002549_A_1")
    }

    /// With RIS answering, bahn.expert isn't asked; the run's stops come from RIS.
    @Test func trainSearchAsksRISNotBahnExpert() async throws {
        let (client, session) = clients()
        defer { session.invalidateAndCancel() }
        let runs = try await client.findTrains(number: 1243, category: "FLX", day: "2026-11-03")
        #expect(runs.first?.category == "FLX")
        let stops = try await client.stops(ofJourney: "20261103-c5ed6631-9860-3f62-aa16-50637daedbaf")
        #expect(stops.first?.name == "Hamburg Dammtor")
        let requests = RISJourneysProtocol.requests.withLock { $0 }
        #expect(requests.allSatisfy { $0.hasPrefix("https://proxy.test/db/apis/ris-journeys/v2/") })
        #expect(requests.first?.contains("limit=1000") == true)
    }

    /// When our server or RIS fails, bahn.expert answers, and RIS is left alone for a while.
    @Test func bahnExpertAnswersWhenRISFails() async throws {
        let (client, session) = clients(risStatus: 502)
        defer { session.invalidateAndCancel() }
        let stops = try await client.stops(ofJourney: "20261103-c5ed6631-9860-3f62-aa16-50637daedbaf")
        #expect(stops.first?.name == "Expert Start")
        _ = try await client.stops(ofJourney: "20261103-c5ed6631-9860-3f62-aa16-50637daedbaf")
        let requests = RISJourneysProtocol.requests.withLock { $0 }
        #expect(requests.filter { $0.contains("proxy.test") }.count == 1)
        #expect(requests.filter { $0.contains("bahn.expert") }.count == 2)
    }

    @Test func journeyIdsWithOtherCharactersArentSent() async throws {
        let (client, session) = clients()
        defer { session.invalidateAndCancel() }
        _ = try? await client.stops(ofJourney: "../find")
        #expect(RISJourneysProtocol.requests.withLock { $0 }.allSatisfy { !$0.contains("proxy.test") })
    }
}

/// Our server with RIS::Journeys (fixtures, or `risStatus`), and bahn.expert with a one-stop run.
private final class RISJourneysProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    static let risStatus = Mutex(200)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.withLock { $0.append(url.absoluteString) }
        var status = 200
        var body = Data()
        if url.host() == "proxy.test" {
            status = Self.risStatus.withLock { $0 }
            let name = url.path().hasSuffix("/find") ? "ris-journeys-find-flx1243" : "ris-journeys-details-ice7"
            if status == 200, let file = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
                body = (try? Data(contentsOf: file)) ?? Data()
            }
        } else {
            body = Data(#"{"json": {"stops": [{"stopPlace": {"evaNumber": "1", "name": "Expert Start"}, "departure": {"scheduledTime": "2026-11-03T11:00:00.000Z"}}]}}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
