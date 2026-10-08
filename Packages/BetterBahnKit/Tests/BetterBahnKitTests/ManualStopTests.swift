import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// A stop added by hand where the train halted outside its timetable (#207).
@Suite struct ManualStopTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func stop(_ name: String, at minutes: Double, delay: Double = 0) -> Stopover {
        let time = TimeInfo(planned: start.addingTimeInterval(minutes * 60), actual: start.addingTimeInterval((minutes + delay) * 60))
        return Stopover(station: station(name, name), arrival: time, departure: time, arrivalPlatform: nil,
                        departurePlatform: nil, cancelled: false)
    }

    private func trip(_ stops: [Stopover]) -> Trip {
        Trip(id: "trip", line: Line(name: "ICE 1", number: "1", product: .highSpeed, operatorName: nil),
             direction: nil, stopovers: stops, cancelled: false, remarks: [], source: .transitous)
    }

    private func manual(_ name: String, at minutes: Double) -> Stopover {
        .manual(at: station(name, name), time: start.addingTimeInterval(minutes * 60))
    }

    @Test func sortsInByLiveTime() throws {
        // B runs 20 minutes late, so a halt at minute 40 comes before it.
        let base = trip([stop("A", at: 0), stop("B", at: 30, delay: 20), stop("C", at: 60)])
        let updated = try #require(base.inserting(manualStop: manual("X", at: 40), boardingAt: station("A", "A")))
        #expect(updated.stopovers.map(\.station.name) == ["A", "X", "B", "C"])
        #expect(updated.stopovers[1].isManual)
        #expect(updated.stopovers[1].arrival?.delayMinutes == nil)
    }

    @Test func goesAfterBoardingAndAtTheEnd() throws {
        let base = trip([stop("A", at: 0), stop("B", at: 30), stop("C", at: 60)])
        // A time before boarding still lands after the boarding stop.
        let early = try #require(base.inserting(manualStop: manual("X", at: -10), boardingAt: station("B", "B")))
        #expect(early.stopovers.map(\.station.name) == ["A", "B", "X", "C"])
        let late = try #require(base.inserting(manualStop: manual("X", at: 90), boardingAt: station("A", "A")))
        #expect(late.stopovers.map(\.station.name) == ["A", "B", "C", "X"])
    }

    @Test func replacesAnEarlierManualStop() throws {
        let base = trip([stop("A", at: 0), stop("B", at: 30), stop("C", at: 60)])
        let first = try #require(base.inserting(manualStop: manual("X", at: 10), boardingAt: station("A", "A")))
        let second = try #require(first.inserting(manualStop: manual("Y", at: 45), boardingAt: station("A", "A")))
        #expect(second.stopovers.map(\.station.name) == ["A", "B", "Y", "C"])
    }

    @Test func refusesUnknownBoardingAndKnownStops() {
        let base = trip([stop("A", at: 0), stop("B", at: 30), stop("C", at: 60)])
        #expect(base.inserting(manualStop: manual("X", at: 10), boardingAt: station("Z", "Z")) == nil)
        #expect(base.inserting(manualStop: manual("C", at: 10), boardingAt: station("A", "A")) == nil)
    }

    @Test func survivesSaving() throws {
        let stop = manual("X", at: 10)
        let decoded = try JSONDecoder().decode(Stopover.self, from: JSONEncoder().encode(stop))
        #expect(decoded.isManual)
        let old = try JSONDecoder().decode(Stopover.self, from: Data(#"{"station":{"id":"A","name":"A","source":"transitous"}}"#.utf8))
        #expect(!old.isManual)
    }

    @Test func legEndsAtTheManualStop() throws {
        let base = trip([stop("A", at: 0), stop("B", at: 30), stop("C", at: 60)])
        let updated = try #require(base.inserting(manualStop: manual("X", at: 40), boardingAt: station("A", "A")))
        let leg = try #require(updated.leg(from: station("A", "A"), to: station("X", "X")))
        #expect(leg.destination.name == "X")
        #expect(leg.arrival.planned == start.addingTimeInterval(40 * 60))
        #expect(leg.stopovers.map(\.station.name) == ["A", "B", "X"])
    }
}

/// Turning a check-in into a manual trip that ends at a stop added by hand.
@Suite(.serialized) struct ReplaceWithManualTripTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private var exitLeg: Leg {
        let departure = TimeInfo(planned: start, actual: nil)
        let arrival = TimeInfo(planned: start.addingTimeInterval(40 * 60), actual: nil)
        return Leg(origin: station("A", "A"), destination: station("X", "X"), departure: departure, arrival: arrival,
                   departurePlatform: nil, arrivalPlatform: nil, tripId: "trip",
                   line: Line(name: "ICE 1", number: "1", product: .highSpeed, operatorName: nil),
                   direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    private func status() throws -> TraewellingStatus {
        try JSONDecoding.decoder.decode(TraewellingStatus.self, from: Data(#"""
        {"id":5,"body":"Störung","visibility":2,"business":1,
         "checkin":{"trip":99,"hafasId":"hafas","lineName":"ICE 1",
          "origin":{"name":"A","departurePlanned":"2026-09-21T13:33:20+00:00"},
          "destination":{"name":"C","arrivalPlanned":"2026-09-21T14:33:20+00:00"}}}
        """#.utf8))
    }

    @Test func createsTripThenReplacesCheckin() async throws {
        let (client, store) = client()
        defer { store.clear() }
        ReplaceProtocol.reset(failing: nil)

        let result = try await client.replaceWithManualTrip(try status(), leg: exitLeg)

        #expect(result.statusId == 77)
        #expect(result.isManualTrip)
        let requests = ReplaceProtocol.requests.withLock { $0 }
        #expect(requests.map(\.entry) == [
            "GET /api/v1/trains/station/autocomplete/A",
            "GET /api/v1/trains/station/autocomplete/X",
            "POST /api/v1/trips",
            "GET /api/v1/status/5/tags",
            "DELETE /api/v1/status/5",
            "POST /api/v1/trains/checkin",
            "POST /api/v1/status/77/tags",
        ])
        let trip = try #require(requests.first { $0.entry == "POST /api/v1/trips" }?.json)
        #expect(trip["originId"] as? Int == 1)
        #expect(trip["destinationId"] as? Int == 2)
        let checkin = try #require(requests.first { $0.entry == "POST /api/v1/trains/checkin" }?.json)
        #expect(checkin["tripId"] as? String == "manual-1")
        #expect(checkin["body"] as? String == "Störung")
        #expect(checkin["visibility"] as? Int == 2)
        #expect(checkin["business"] as? Int == 1)
        #expect(checkin["toot"] as? Bool == false)
        let tag = try #require(requests.last?.json)
        #expect(tag["key"] as? String == "trwl:seat")
        #expect(tag["value"] as? String == "61")
    }

    @Test func keepsCheckinWhenTripFails() async throws {
        let (client, store) = client()
        defer { store.clear() }
        ReplaceProtocol.reset(failing: "POST /api/v1/trips")

        await #expect(throws: TraewellingError.self) {
            try await client.replaceWithManualTrip(try status(), leg: exitLeg)
        }
        #expect(!ReplaceProtocol.requests.withLock { $0 }.contains { $0.entry.hasPrefix("DELETE") })
    }

    private func client() -> (TraewellingClient, TokenStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplaceProtocol.self]
        let store = TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        store.save(OAuthToken(accessToken: "test-token", refreshToken: nil, expiresAt: .distantFuture))
        let client = TraewellingClient(config: TraewellingConfig(clientID: "public-client"),
                                       http: HTTPClient(session: URLSession(configuration: configuration)), store: store)
        return (client, store)
    }
}

/// Records "METHOD /path" with the JSON body and answers like Träwelling: station "A" is id 1, any
/// other station id 2, the manual trip "manual-1", the new check-in status 77. `failing` gets a 500.
private final class ReplaceProtocol: URLProtocol, @unchecked Sendable {
    struct Request: @unchecked Sendable {
        var entry: String
        var json: [String: Any]?
    }

    static let requests = Mutex<[Request]>([])
    nonisolated(unsafe) static var failing: String?

    static func reset(failing: String?) {
        requests.withLock { $0 = [] }
        self.failing = failing
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path(percentEncoded: false)
        let entry = "\(request.httpMethod ?? "GET") \(path)"
        let json = bodyData().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        Self.requests.withLock { $0.append(Request(entry: entry, json: json)) }
        var status = 200
        let body: String
        if entry == Self.failing {
            status = 500
            body = #"{"message":"Fehler"}"#
        } else if path.contains("/autocomplete/") {
            let name = url.lastPathComponent
            body = #"{"data":[{"id":\#(name == "A" ? 1 : 2),"name":"\#(name)"}]}"#
        } else if entry == "POST /api/v1/trips" {
            body = #"{"data":{"tripId":"manual-1","lineName":"ICE 1","origin":{"id":1},"destination":{"id":2}}}"#
        } else if entry == "POST /api/v1/trains/checkin" {
            body = #"{"data":{"status":{"id":77},"points":{"points":4},"alsoOnThisConnection":[]}}"#
        } else if entry.hasPrefix("GET") && entry.hasSuffix("/tags") {
            body = #"{"data":[{"key":"trwl:seat","value":"61","visibility":0}]}"#
        } else if entry.hasSuffix("/tags") {
            body = #"{"data":{"key":"trwl:seat","value":"61","visibility":0}}"#
        } else {
            body = #"{"data":null}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands the body over as a stream.
    private func bodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
