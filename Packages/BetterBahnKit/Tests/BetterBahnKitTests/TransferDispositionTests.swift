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

    @Test func asksOnlyAboutTransfersCloseToNow() {
        let journey = Journey(legs: [ice91, re3], source: .transitous)
        // ICE 91 gets in at 08:32 UTC (41 min late).
        #expect(BahnExpertClient.transfersToAsk(in: journey, now: date("2026-10-08T06:00:00Z")).count == 1)
        #expect(BahnExpertClient.transfersToAsk(in: journey, now: date("2026-10-08T08:40:00Z")).count == 1)
        #expect(BahnExpertClient.transfersToAsk(in: journey, now: date("2026-10-08T05:00:00Z")).isEmpty)
        #expect(BahnExpertClient.transfersToAsk(in: journey, now: date("2026-10-08T09:00:00Z")).isEmpty)
        var cancelled = journey
        cancelled.legs[1].cancelled = true
        #expect(BahnExpertClient.transfersToAsk(in: cancelled, now: date("2026-10-08T08:00:00Z")).isEmpty)
    }

    @Test func notifiesOncePerDecision() {
        let notWaiting = TransferDispositionUpdate(arriving: ice91, departing: re3, disposition: .notWaiting)
        let waiting = TransferDispositionUpdate(arriving: ice91, departing: re3, disposition: .waiting)
        let undecided = TransferDispositionUpdate(arriving: ice91, departing: re3, disposition: nil)
        #expect(notWaiting.notificationID != nil)
        #expect(notWaiting.notificationID != waiting.notificationID)
        #expect(undecided.notificationID == nil)
        #expect(TransferDisposition.notWaiting.message(arriving: ice91, departing: re3) == "RE3 wartet in Berlin Hbf nicht auf ICE 91.")
        #expect(TransferDisposition.waiting.message(arriving: ice91, departing: re3) == "RE3 wartet in Berlin Hbf auf ICE 91.")
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

        let updates = await client.dispositions(in: Journey(legs: [ice91, re3], source: .transitous), now: date("2026-10-08T08:00:00Z"))
        #expect(updates.map(\.disposition) == [.notWaiting])
    }

    /// ICE 91 gets in at 08:32, RE3 leaves at 08:23: missed, unless DB lets RE3 wait for it.
    @Test func waitingTrainMakesTransferWork() throws {
        let journey = Journey(legs: [ice91, re3], source: .transitous)
        #expect(journey.connectionIssues().contains { $0.isBlocking })
        #expect(journey.brokenTransferIndices == [1])

        let waits = TransferDispositionUpdate(arriving: ice91, departing: re3, disposition: .waiting)
        let held = journey.applying([waits])
        #expect(held.connectionIssues().isEmpty)
        #expect(held.brokenTransferIndices.isEmpty)
        let status = try #require(JourneyLiveStatus.at(date("2026-10-08T08:25:00Z"), of: held))
        #expect(status.nextTransfer?.disposition == .waiting)
        #expect(status.nextTransfer?.isMissed == false)
        #expect(held.id == journey.id)

        // RE3 doesn't wait (any more), or nothing is decided now: missed again.
        let notWaiting = TransferDispositionUpdate(arriving: ice91, departing: re3, disposition: .notWaiting)
        #expect(held.applying([notWaiting]).connectionIssues().contains { $0.isBlocking })
        let undecided = TransferDispositionUpdate(arriving: ice91, departing: re3, disposition: nil)
        #expect(held.applying([undecided]).legs[1].waitDecision == nil)
        // No update for the transfer keeps the decision.
        #expect(held.applying([]).connectionIssues().isEmpty)
    }

    /// RE3 waits for ICE 91, not for another train put before it ("Anderer Zug").
    @Test func decisionOnlyForItsTrain() {
        let held = Journey(legs: [ice91, re3], source: .transitous)
            .applying([TransferDispositionUpdate(arriving: ice91, departing: re3, disposition: .waiting)])
        var other = ice91
        other.tripId = "ice93"
        other.departure.planned = date("2026-10-08T06:00:00Z")
        let replaced = Journey(legs: [other, held.legs[1]], source: .transitous)
        #expect(replaced.connectionIssues().contains { $0.isBlocking })
        #expect(replaced.brokenTransferIndices == [1])
    }

    /// Journeys saved before the decision was remembered still load, and it survives saving.
    @Test func decisionRoundTrips() throws {
        let held = Journey(legs: [ice91, re3], source: .transitous)
            .applying([TransferDispositionUpdate(arriving: ice91, departing: re3, disposition: .waiting)])
        let decoded = try JSONDecoder().decode(Journey.self, from: JSONEncoder().encode(held))
        #expect(decoded == held)
        #expect(decoded.legs[1].waitDecision?.disposition == .waiting)
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
