import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

@Suite struct StatusTagChangesTests {
    private let seat = StatusTag(key: "trwl:seat", value: "61", visibility: .unlisted)
    private let wagon = StatusTag(key: "trwl:wagon", value: "7", visibility: .publicVisible)

    @Test func addsUpdatesAndRemoves() {
        let changes = StatusTagChanges(
            from: [seat, wagon],
            to: [StatusTag(key: "trwl:seat", value: " 62 ", visibility: nil),
                 StatusTag(key: "trwl:ticket", value: "BahnCard 100", visibility: .publicVisible)])
        // The changed tag keeps the visibility it had.
        #expect(changes.updated == [StatusTag(key: "trwl:seat", value: "62", visibility: .unlisted)])
        #expect(changes.added == [StatusTag(key: "trwl:ticket", value: "BahnCard 100", visibility: .publicVisible)])
        #expect(changes.removed == ["trwl:wagon"])
    }

    @Test func emptyValueRemovesAndUnchangedDoesNothing() {
        let changes = StatusTagChanges(from: [seat, wagon],
                                       to: [seat, StatusTag(key: "trwl:wagon", value: "  ", visibility: nil),
                                            StatusTag(key: "trwl:ticket", value: "", visibility: nil)])
        #expect(changes.added.isEmpty)
        #expect(changes.updated.isEmpty)
        #expect(changes.removed == ["trwl:wagon"])
        #expect(StatusTagChanges(from: [seat], to: [seat]).isEmpty)
    }

    @Test func unknownTagVisibilityStillDecodes() throws {
        let tag = try JSONDecoding.decoder.decode(StatusTag.self, from: Data(#"{"key":"x","value":"y","visibility":42}"#.utf8))
        #expect(tag.value == "y")
        #expect(tag.visibility == nil)
    }
}

/// Checking out of a ride that is under way ends it where the train last stopped.
@Suite struct TraewellingEarlyExitTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func stop(_ name: String, at minutes: Double, delay: Double = 0, access: StopAccess = .normal,
                      cancelled: Bool = false, additional: Bool = false) -> Stopover {
        let time = TimeInfo(planned: start.addingTimeInterval(minutes * 60), actual: start.addingTimeInterval((minutes + delay) * 60))
        return Stopover(station: station(name, name), arrival: time, departure: time, arrivalPlatform: nil,
                        departurePlatform: nil, cancelled: cancelled, access: access, isAdditional: additional)
    }

    private func leg(_ stops: [Stopover]) -> Leg {
        Leg(origin: stops.first!.station, destination: stops.last!.station,
            departure: stops.first!.departure!, arrival: stops.last!.arrival!,
            departurePlatform: nil, arrivalPlatform: nil, tripId: "trip",
            line: Line(name: "ICE 1", number: "1", product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false, stopovers: stops, remarks: [], source: .transitous)
    }

    @Test func lastReachedStop() {
        let ride = leg([stop("A", at: 0), stop("B", at: 30), stop("C", at: 60), stop("D", at: 90)])
        #expect(TraewellingClient.earlyExit(on: ride, at: start.addingTimeInterval(65 * 60))?.station.name == "C")
        // Before the train reaches its first stop after boarding, the next one is the earliest exit.
        #expect(TraewellingClient.earlyExit(on: ride, at: start.addingTimeInterval(10 * 60))?.station.name == "B")
    }

    @Test func usesLiveTimes() {
        let ride = leg([stop("A", at: 0), stop("B", at: 30, delay: 10), stop("C", at: 60, delay: 10), stop("D", at: 90)])
        #expect(TraewellingClient.earlyExit(on: ride, at: start.addingTimeInterval(65 * 60))?.station.name == "B")
    }

    @Test func skipsStopsWithoutExit() {
        let ride = leg([stop("A", at: 0), stop("B", at: 20), stop("C", at: 30, access: .entryOnly),
                        stop("D", at: 40, cancelled: true), stop("E", at: 50, additional: true), stop("F", at: 90)])
        #expect(TraewellingClient.earlyExit(on: ride, at: start.addingTimeInterval(55 * 60))?.station.name == "B")
    }

    @Test func nothingOutsideTheRide() {
        let ride = leg([stop("A", at: 0), stop("B", at: 30), stop("C", at: 60)])
        #expect(TraewellingClient.earlyExit(on: ride, at: start.addingTimeInterval(-60)) == nil)
        #expect(TraewellingClient.earlyExit(on: ride, at: start.addingTimeInterval(61 * 60)) == nil)
        #expect(TraewellingClient.earlyExit(on: leg([stop("A", at: 0), stop("C", at: 60)]), at: start.addingTimeInterval(600)) == nil)
    }
}

@Suite(.serialized) struct TraewellingCheckinEditRequestTests {
    @Test func deletingAGoneCheckinSucceeds() async throws {
        let (client, store) = client()
        defer { store.clear() }
        CheckinEditProtocol.reset(statusFor: { _ in 404 })

        try await client.deleteStatus(id: 42)

        #expect(CheckinEditProtocol.requests.withLock { $0 } == ["DELETE /api/v1/status/42"])
    }

    @Test func appliesTagChanges() async throws {
        let (client, store) = client()
        defer { store.clear() }
        CheckinEditProtocol.reset(statusFor: { _ in 200 })

        let tags = try await client.applyTagChanges(
            statusId: 7,
            from: [StatusTag(key: "trwl:seat", value: "61", visibility: .publicVisible),
                   StatusTag(key: "trwl:wagon", value: "7", visibility: .publicVisible)],
            to: [StatusTag(key: "trwl:seat", value: "62", visibility: nil),
                 StatusTag(key: "trwl:ticket", value: "BC100", visibility: .publicVisible)])

        #expect(CheckinEditProtocol.requests.withLock { $0 } == [
            "DELETE /api/v1/status/7/tags/trwl:wagon",
            "PUT /api/v1/status/7/tags/trwl:seat",
            "POST /api/v1/status/7/tags",
            "GET /api/v1/status/7/tags",
        ])
        #expect(tags.map(\.key) == ["trwl:seat", "trwl:ticket"])
    }

    private func client() -> (TraewellingClient, TokenStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckinEditProtocol.self]
        let store = TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        store.save(OAuthToken(accessToken: "test-token", refreshToken: nil, expiresAt: .distantFuture))
        let client = TraewellingClient(config: TraewellingConfig(clientID: "public-client"),
                                       http: HTTPClient(session: URLSession(configuration: configuration)), store: store)
        return (client, store)
    }
}

/// Records "METHOD /path" and answers each request with the given status; tag requests get a tag
/// back, the tag list two tags.
private final class CheckinEditProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    nonisolated(unsafe) static var statusFor: (String) -> Int = { _ in 200 }

    static func reset(statusFor: @escaping (String) -> Int) {
        requests.withLock { $0 = [] }
        self.statusFor = statusFor
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let entry = "\(request.httpMethod ?? "GET") \(url.path(percentEncoded: false))"
        Self.requests.withLock { $0.append(entry) }
        let status = Self.statusFor(entry)
        let body: String
        if status != 200 {
            body = #"{"message":"Not found"}"#
        } else if entry.hasPrefix("GET") && entry.hasSuffix("/tags") {
            body = #"{"data":[{"key":"trwl:seat","value":"62","visibility":0},{"key":"trwl:ticket","value":"BC100","visibility":0}]}"#
        } else if entry.contains("/tags") && !entry.hasPrefix("DELETE") {
            body = #"{"data":{"key":"trwl:seat","value":"62","visibility":0}}"#
        } else {
            body = #"{"data":null}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
