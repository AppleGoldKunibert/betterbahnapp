import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct ProviderMigrationTests {
    @Test func defaultsToTransitous() {
        let provider = CombinedProvider()
        #expect(provider.source == .transitous)
        #expect(provider.primary is TransitousProvider)
        #expect(provider.fallback == nil)
    }

    @Test func legacyStationsStillDecodeAndReachPrimary() async throws {
        let data = Data(#"{"id":"8000207","name":"Köln Hbf","evaNumber":"8000207","source":"dbRest"}"#.utf8)
        let saved = try JSONDecoder().decode(Station.self, from: data)
        #expect(saved.source == .dbRest)
        let primary = MockProvider(source: .transitous)
        let provider = CombinedProvider(primary: primary, bahnDe: nil)
        _ = try await provider.journeys(JourneyQuery(from: saved, to: saved, date: .now))
        _ = try await provider.departures(at: saved)
        #expect(primary.calls == ["journeys", "board"])
    }

    @Test func paginationStaysOnTransitousAndStripsPrefix() async throws {
        let primary = MockProvider(source: .transitous)
        primary.journeyPages = [JourneyPage(journeys: [], earlierCursor: "earlier", laterCursor: "later", source: .transitous)]
        let fallback = MockProvider(source: .bahnDe)
        let provider = CombinedProvider(primary: primary, fallback: fallback, bahnDe: nil)
        let stop = station("old", "Berlin Hbf", source: .dbRest)
        let query = JourneyQuery(from: stop, to: stop, date: .now, cursor: "transitous:opaque:cursor")
        let page = try await provider.journeys(query)
        #expect(primary.receivedCursors == ["opaque:cursor"])
        #expect(page.laterCursor == "transitous:later")
        #expect(page.earlierCursor == "transitous:earlier")
        primary.failing = true
        await #expect(throws: TransitError.self) { try await provider.journeys(query) }
        #expect(fallback.calls.isEmpty)
    }

    @Test func retiredTripIDsAndCursorsNeverReachTransitous() async throws {
        let primary = MockProvider(source: .transitous)
        let provider = CombinedProvider(primary: primary, bahnDe: nil)
        await #expect(throws: TransitError.self) { try await provider.trip(id: "legacy", source: .dbRest) }
        let stop = station("old", "Berlin Hbf", source: .dbRest)
        await #expect(throws: TransitError.self) {
            try await provider.journeys(JourneyQuery(from: stop, to: stop, date: .now, cursor: "dbRest:old"))
        }
        #expect(primary.calls.isEmpty)
    }

    @Test func transitousTripUsesPrimary() async throws {
        let primary = MockProvider(source: .transitous)
        primary.trips["trip"] = Trip(id: "trip", line: nil, direction: nil, stopovers: [], cancelled: false, remarks: [], source: .transitous)
        let fallback = MockProvider(source: .bahnDe)
        let provider = CombinedProvider(primary: primary, fallback: fallback, bahnDe: nil)
        let trip = try await provider.trip(id: "trip", source: .transitous)
        #expect(trip.source == .transitous)
        #expect(primary.calls == ["trip"])
        #expect(fallback.calls.isEmpty)
    }

    @Test func noFallbackPreservesErrorAndAllowsRetry() async throws {
        let primary = MockProvider(source: .transitous)
        let provider = CombinedProvider(primary: primary, bahnDe: nil)
        primary.failing = true
        await #expect(throws: TransitError.http(status: 503, body: nil)) { try await provider.searchStations("Berlin") }
        primary.failing = false
        let stations = try await provider.searchStations("Berlin")
        #expect(stations.first?.source == .transitous)
        #expect(primary.calls.count == 2)
    }

    @Test func cancellationDoesNotTriggerFallback() async throws {
        let primary = MockProvider(source: .transitous)
        let fallback = MockProvider(source: .bahnDe)
        let provider = CombinedProvider(primary: primary, fallback: fallback, bahnDe: nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.searchStations("Berlin")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(primary.calls.isEmpty)
        #expect(fallback.calls.isEmpty)
    }

    @Test func resolvesLegacyStationAndIdentifiesTransitousRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransitousMigrationProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))
        let stop = try await provider.resolve(station("8000207", "Köln Hbf", 50.943, 6.958, source: .dbRest))
        #expect(stop.source == .transitous)
        #expect(stop.id == "de:test:koeln")
    }
}

private final class TransitousMigrationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.host == "api.transitous.org")
        #expect(request.url?.path == "/api/v1/geocode")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == HTTPClient.identifyingUserAgent)
        let body = Data(#"[{"id":"de:test:koeln","name":"Köln Hbf","type":"STOP","lat":50.943,"lon":6.958}]"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
