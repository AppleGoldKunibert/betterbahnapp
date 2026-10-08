import Foundation
import Testing
@testable import BetterBahnKit

/// Whether a connecting train waits, from bahn.expert's connections. Real responses for ICE 91
/// (41 min late) at Berlin Hbf on 2026-10-08: DB let RE 3 (3346) go without it, ICE 507 has no decision.
@Suite struct TransferDispositionTests {
    let day = ISO8601DateFormatter()

    func date(_ string: String) -> Date { day.date(from: string)! }

    var ice91: Leg {
        Leg(origin: station("hh", "Hamburg Hbf", source: .transitous),
            destination: Station(id: "berlin", name: "Berlin Hbf", coordinate: nil, evaNumber: "8098160", source: .transitous),
            departure: TimeInfo(planned: date("2026-10-08T05:50:00Z"), actual: nil),
            arrival: TimeInfo(planned: date("2026-10-08T07:51:00Z"), actual: date("2026-10-08T08:32:00Z")),
            departurePlatform: nil, arrivalPlatform: nil, tripId: "ice91",
            line: Line(name: "ICE 91", number: "91", product: .highSpeed, operatorName: nil), direction: nil,
            isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    func departing(_ line: Line, at time: String) -> Leg {
        Leg(origin: station("berlin", "Berlin Hbf", source: .transitous), destination: station("x", "X", source: .transitous),
            departure: TimeInfo(planned: date(time), actual: nil), arrival: TimeInfo(planned: date(time).addingTimeInterval(3600), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: line.name, line: line, direction: nil,
            isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    var re3: Leg {
        departing(Line(name: "RE3", number: "3", product: .regionalExpress, operatorName: nil, tripNumber: "3346"), at: "2026-10-08T08:23:00Z")
    }

    @Test func statusTypes() {
        #expect(TransferDisposition(type: "NOT_WAITING") == .notWaiting)
        #expect(TransferDisposition(type: "WAITING") == .waiting)
        #expect(TransferDisposition(type: nil) == nil)
        #expect(TransferDisposition(type: "UNKNOWN") == nil)
    }

    @Test func findsArrivalStopByEvaOrTime() throws {
        let stops = try fixture("bahnexpert-details-ice91", as: BahnExpertClient.Envelope<BahnExpertClient.DetailsWithIDs>.self).json.stops
        #expect(BahnExpertClient.arrivalStop(of: ice91, in: stops)?.arrival?.id == "8098160_A_1")
        var withoutEva = ice91
        withoutEva.destination.evaNumber = nil
        #expect(BahnExpertClient.arrivalStop(of: withoutEva, in: stops)?.arrival?.id == "8098160_A_1")
    }

    @Test func matchesDepartingTrain() throws {
        let connections = try fixture("bahnexpert-connections", as: BahnExpertClient.Envelope<BahnExpertClient.ConnectionsResponse>.self).json.connections
        let re = try #require(BahnExpertClient.connection(to: re3, in: connections))
        #expect(TransferDisposition(type: re.dispositionStatus?.type) == .notWaiting)

        let ice507 = departing(Line(name: "ICE 507", number: "507", product: .highSpeed, operatorName: nil), at: "2026-10-08T08:29:00Z")
        let ice = try #require(BahnExpertClient.connection(to: ice507, in: connections))
        #expect(ice.dispositionStatus == nil)

        // Without a run number the name and planned time still find it.
        let unnumbered = departing(Line(name: "RE 3", number: nil, product: .regionalExpress, operatorName: nil), at: "2026-10-08T08:23:00Z")
        #expect(BahnExpertClient.connection(to: unnumbered, in: connections)?.transport.number == 3346)
        // The same train an hour later is another run.
        #expect(BahnExpertClient.connection(to: departing(re3.line!, at: "2026-10-08T09:23:00Z"), in: connections) == nil)
    }

    @Test func looksUpDispositionThroughBahnExpert() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BahnExpertConnectionsProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = BahnExpertClient(http: HTTPClient(session: session))

        #expect(try await client.disposition(from: ice91, to: re3) == .notWaiting)
        let ice507 = departing(Line(name: "ICE 507", number: "507", product: .highSpeed, operatorName: nil), at: "2026-10-08T08:29:00Z")
        #expect(try await client.disposition(from: ice91, to: ice507) == nil)
    }
}

private final class BahnExpertConnectionsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let data: Data
        if path.hasSuffix("journey/find") {
            data = Data(#"{"json":[{"journeyId":"20261008-bd530734-4a1e-3ab8-9477-165f68834269","train":{"category":"ICE","journeyNumber":91}}]}"#.utf8)
        } else {
            let name = path.hasSuffix("connections/connections") ? "bahnexpert-connections" : "bahnexpert-details-ice91"
            let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
            data = (try? Data(contentsOf: url)) ?? Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
