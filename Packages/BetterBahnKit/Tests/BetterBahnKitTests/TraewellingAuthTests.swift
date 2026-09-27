import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct TraewellingAuthTests {
    private let redirectURI = "https://betterbahn.kunibert88.workers.dev/oauth/traewelling/callback"

    @Test func defaultHTTPSCallback() {
        let config = TraewellingConfig(clientID: "public-client")
        #expect(config.redirectURI == redirectURI)
        #expect(config.callbackHost == "betterbahn.kunibert88.workers.dev")
        #expect(config.callbackPath == "/oauth/traewelling/callback")
        #expect(config.callbackScheme == "betterbahn")
    }

    @Test func callbackComponentsFollowRedirectURI() {
        var config = TraewellingConfig(clientID: "public-client")
        config.redirectURI = "https://example.com/another/callback"
        #expect(config.callbackHost == "example.com")
        #expect(config.callbackPath == "/another/callback")
    }

    @Test(arguments: ["", "not a URL", "http://example.com/callback", "example:/callback",
                      "https:///callback", "https://example.com", "https://exa mple.com/callback",
                      "https://example.com/call back", "https://user:password@example.com/callback",
                      "https://example.com/callback#fragment"])
    func invalidCallbacksAreRejected(_ redirectURI: String) {
        let config = TraewellingConfig(clientID: "public-client", redirectURI: redirectURI)
        #expect(config.callbackHost == nil)
        #expect(config.callbackPath == nil)
        #expect(OAuthError.invalidRedirectURI.localizedDescription.contains("HTTPS"))
    }

    @Test func authorizationRequestPreservesPKCEAndPublicClientParameters() throws {
        let config = TraewellingConfig(clientID: "public-client")
        let pkce = PKCE()
        let components = try #require(URLComponents(url: config.authorizeURL(pkce: pkce), resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(parameters == [
            "client_id": "public-client",
            "redirect_uri": redirectURI,
            "response_type": "code",
            "scope": "read-statuses write-statuses read-search",
            "state": pkce.state,
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
        ])
        #expect(parameters["client_secret"] == nil)
    }

    @Test func tokenExchangePreservesRedirectURIAndVerifier() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthTokenRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = TraewellingClient(
            config: TraewellingConfig(clientID: "public-client"),
            http: HTTPClient(session: session),
            store: TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        )
        let callback = try #require(URL(string: "betterbahn://oauth?code=test-code&state=test-state"))
        // The mock rejects the exchange after inspecting it, so no token is written to Keychain.
        await #expect(throws: TransitError.http(status: 400, body: "{}")) {
            try await client.completeLogin(callbackURL: callback, pkce: PKCE(verifier: "test-verifier", state: "test-state"))
        }
        await #expect(throws: OAuthError.stateMismatch) {
            try await client.completeLogin(callbackURL: callback, pkce: PKCE(state: "wrong-state"))
        }
    }

    @Test func updateCheckinSendsBothManualTimeKeySpellings() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusUpdateRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        store.save(OAuthToken(accessToken: "test-token", refreshToken: nil, expiresAt: .distantFuture))
        let client = TraewellingClient(
            config: TraewellingConfig(clientID: "public-client"),
            http: HTTPClient(session: session),
            store: store
        )
        let departure = Date(timeIntervalSince1970: 1_700_000_000)
        let arrival = Date(timeIntervalSince1970: 1_700_003_600)
        _ = try await client.updateCheckin(statusId: 42, departure: departure, arrival: arrival)
    }
}

/// Real-world case: ICE 372 skipped Frankfurt (Main) Hbf on 2026-09-22 and picked up an unscheduled
/// stop at Frankfurt (Main) Süd instead — Träwelling's own timetable data never has a Zusatzhalt like
/// that, so a plain checkin from there always fails with `.tripNotFound` even though Träwelling knows
/// the train. `checkin(_:fromZusatzhalt:toNextRegularStop:)` is what bridges that gap: a short manual
/// trip for the Zusatzhalt hop, then an ordinary HAFAS-matched checkin from the next regular stop
/// onwards, end to end against a mocked Träwelling API.
@Suite struct TraewellingZusatzhaltCheckinTests {
    static let zusatzhaltDeparture = TimeInfo(planned: Date(timeIntervalSince1970: 1_790_161_140), actual: Date(timeIntervalSince1970: 1_790_163_484))
    static let nextRegularArrival = Date(timeIntervalSince1970: 1_790_161_680)
    static let nextRegularDeparture = Date(timeIntervalSince1970: 1_790_161_800)
    static let finalArrival = Date(timeIntervalSince1970: 1_790_170_000)

    @Test func bridgesTheZusatzhaltWithAManualTripThenChecksInNormally() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZusatzhaltCheckinProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        store.save(OAuthToken(accessToken: "test-token", refreshToken: nil, expiresAt: .distantFuture))
        let client = TraewellingClient(config: TraewellingConfig(clientID: "public-client"), http: HTTPClient(session: session), store: store)

        let hanau = station("8000150", "Hanau Hbf", 50.1066, 8.9166)
        let leg = Leg(origin: station("8002041", "Frankfurt (Main) Süd", 50.0937, 8.6822),
                     destination: station("8098160", "Berlin Hbf", 52.5251, 13.3694),
                     departure: Self.zusatzhaltDeparture,
                     arrival: TimeInfo(planned: Self.finalArrival, actual: nil),
                     departurePlatform: nil, arrivalPlatform: nil, tripId: "transitous-trip",
                     line: Line(name: "ICE 372", number: "372", product: .highSpeed, operatorName: "DB Fernverkehr AG"),
                     direction: "Berlin Hbf", isWalking: false, cancelled: false,
                     stopovers: [Stopover(station: hanau, arrival: nil, departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: false)],
                     remarks: [], source: .transitous)
        let draft = CheckinDraft(leg: leg, message: "unterwegs", visibility: .publicVisible, business: .privateTrip, toot: false)

        let json = """
        {"stops": [
            {"stopPlace": {"evaNumber": "8002041", "name": "Frankfurt (Main) Süd"},
             "departure": {"scheduledTime": "2026-09-22T11:19:00Z", "time": "2026-09-22T11:58:04Z", "additional": true},
             "additional": true},
            {"stopPlace": {"evaNumber": "8000150", "name": "Hanau Hbf"},
             "arrival": {"scheduledTime": "2026-09-22T11:28:00Z", "time": "2026-09-22T12:07:20Z"},
             "departure": {"scheduledTime": "2026-09-22T11:30:00Z", "time": "2026-09-22T12:09:01Z"}}
        ]}
        """
        let details = try JSONDecoding.decoder.decode(BahnExpertClient.Details.self, from: Data(json.utf8))
        let stops = details.stops.map(JourneyStop.init)

        let result = try await client.checkin(draft, fromZusatzhalt: stops[0], toNextRegularStop: stops[1])

        #expect(result.statusId == 9002)
        #expect(result.points == 47)
        #expect(result.alsoOnThisConnection == 2)
        #expect(result.zusatzhaltHop?.statusId == 9001)
        #expect(result.zusatzhaltHop?.leg.origin.name == "Frankfurt (Main) Süd")
        #expect(result.zusatzhaltHop?.leg.destination.name == "Hanau Hbf")
    }
}

/// Real-world case: the IC Zürich HB – Stuttgart Hbf is one run in Transitous, but Träwelling splits
/// it at the border into a Swiss trip ending in Singen (Hohentwiel) and a German one from there, so
/// Stuttgart was never on the trip found at Zürich and the checkin failed with `.stopNotOnTrip`.
/// Now each part is checked in one after the other.
@Suite struct TraewellingSplitTrainCheckinTests {
    static func time(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    static let zurich = station("8503000", "Zürich HB", 47.3782, 8.5402)
    static let schaffhausen = station("8503424", "Schaffhausen", 47.6981, 8.6325)
    static let singen = station("8000073", "Singen (Hohentwiel)", 47.7590, 8.8403)
    static let stuttgart = station("8000096", "Stuttgart Hbf", 48.7843, 9.1818)

    static let leg: Leg = {
        func stop(_ station: Station, arr: String?, dep: String?) -> Stopover {
            Stopover(station: station, arrival: arr.map { TimeInfo(planned: time($0), actual: nil) },
                     departure: dep.map { TimeInfo(planned: time($0), actual: nil) },
                     arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        return Leg(origin: zurich, destination: stuttgart,
                   departure: TimeInfo(planned: time("2026-09-27T06:04:00Z"), actual: nil),
                   arrival: TimeInfo(planned: time("2026-09-27T08:20:00Z"), actual: nil),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: "transitous-trip",
                   line: Line(name: "IC 181", number: "181", product: .longDistance, operatorName: "DB Fernverkehr AG"),
                   direction: "Stuttgart Hbf", isWalking: false, cancelled: false,
                   stopovers: [stop(zurich, arr: nil, dep: "2026-09-27T06:04:00Z"),
                               stop(schaffhausen, arr: "2026-09-27T06:40:00Z", dep: "2026-09-27T06:42:00Z"),
                               stop(singen, arr: "2026-09-27T06:55:00Z", dep: "2026-09-27T06:58:00Z"),
                               stop(stuttgart, arr: "2026-09-27T08:20:00Z", dep: nil)],
                   remarks: [], source: .transitous)
    }()

    @Test func checksInEachPartOfATrainTraewellingSplitsAtTheBorder() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SplitTrainCheckinProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        store.save(OAuthToken(accessToken: "test-token", refreshToken: nil, expiresAt: .distantFuture))
        let client = TraewellingClient(config: TraewellingConfig(clientID: "public-client"), http: HTTPClient(session: session), store: store)

        let result = try await client.checkin(CheckinDraft(leg: Self.leg, message: "Gäubahn"))

        #expect(result.statusId == 8001)
        #expect(result.connectingStatusIds == [8002])
        #expect(result.points == 30)
        #expect(!result.isManualTrip)
    }

    @Test func splitStopoverIsTheIntermediateStopWhereTraewellingsTripEnds() throws {
        let end = try JSONDecoding.decoder.decode(TraewellingTrip.Stop.self, from: Data("""
        {"id":200,"name":"Singen(Hohentwiel)","station":{"id":200,"name":"Singen(Hohentwiel)","latitude":47.7591,"longitude":8.8401},
         "arrivalPlanned":"2026-09-27T06:55:00Z"}
        """.utf8))
        let split = try #require(TraewellingClient.splitStopover(tripEnd: end, in: Self.leg.stopovers))
        #expect(split.station == Self.singen)

        let rest = try #require(TraewellingClient.remainder(of: Self.leg, from: split))
        #expect(rest.origin == Self.singen)
        #expect(rest.departure.planned == Self.time("2026-09-27T06:58:00Z"))
        #expect(rest.stopovers.map(\.station) == [Self.singen, Self.stuttgart])

        // Träwelling's trip ending at our own destination (or origin) is no split.
        var atDestination = end
        atDestination.name = "Stuttgart Hbf"
        atDestination.station = nil
        atDestination.arrivalPlanned = Self.time("2026-09-27T08:20:00Z")
        #expect(TraewellingClient.splitStopover(tripEnd: atDestination, in: Self.leg.stopovers) == nil)
    }
}

private final class SplitTrainCheckinProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = Self.body(of: request)
        let json: String
        switch true {
        case path.contains("autocomplete") && path.contains("Zürich"):
            json = #"{"data":[{"id":100,"name":"Zürich HB","latitude":47.3782,"longitude":8.5402}]}"#
        case path.contains("autocomplete") && path.contains("Singen"):
            json = #"{"data":[{"id":200,"name":"Singen(Hohentwiel)","latitude":47.7591,"longitude":8.8401}]}"#
        case path == "/api/v1/station/100/departures":
            json = """
            {"data":[{"tripId":"ch-trip","plannedWhen":"2026-09-27T06:04:00Z",
                      "line":{"name":"IC 181","fahrtNr":"181"},"direction":"Singen(Hohentwiel)"}]}
            """
        case path == "/api/v1/station/200/departures":
            json = """
            {"data":[{"tripId":"de-trip","plannedWhen":"2026-09-27T06:58:00Z",
                      "line":{"name":"IC 181","fahrtNr":"181"},"direction":"Stuttgart Hbf"}]}
            """
        case path == "/api/v1/trains/trip" && query.contains(.init(name: "hafasTripId", value: "ch-trip")):
            json = """
            {"data":{"id":1,"lineName":"IC 181","stopovers":[
                {"id":100,"name":"Zürich HB","station":{"id":100,"name":"Zürich HB"},"departurePlanned":"2026-09-27T06:04:00Z"},
                {"id":150,"name":"Schaffhausen","station":{"id":150,"name":"Schaffhausen"},"arrivalPlanned":"2026-09-27T06:40:00Z","departurePlanned":"2026-09-27T06:42:00Z"},
                {"id":200,"name":"Singen(Hohentwiel)","station":{"id":200,"name":"Singen(Hohentwiel)","latitude":47.7591,"longitude":8.8401},"arrivalPlanned":"2026-09-27T06:55:00Z"}
            ]}}
            """
        case path == "/api/v1/trains/trip" && query.contains(.init(name: "hafasTripId", value: "de-trip")):
            json = """
            {"data":{"id":2,"lineName":"IC 181","stopovers":[
                {"id":200,"name":"Singen(Hohentwiel)","station":{"id":200,"name":"Singen(Hohentwiel)"},"departurePlanned":"2026-09-27T06:58:00Z"},
                {"id":300,"name":"Stuttgart Hbf","station":{"id":300,"name":"Stuttgart Hbf"},"arrivalPlanned":"2026-09-27T08:20:00Z"}
            ]}}
            """
        case path == "/api/v1/trains/checkin" && body?["tripId"] as? String == "ch-trip":
            #expect(body?["start"] as? Int == 100)
            #expect(body?["destination"] as? Int == 200)
            #expect(body?["arrival"] as? String == "2026-09-27T06:55:00Z")
            #expect(body?["body"] as? String == "Gäubahn")
            json = #"{"data":{"status":{"id":8001},"points":{"points":12},"alsoOnThisConnection":[]}}"#
        case path == "/api/v1/trains/checkin" && body?["tripId"] as? String == "de-trip":
            #expect(body?["start"] as? Int == 200)
            #expect(body?["destination"] as? Int == 300)
            #expect(body?["departure"] as? String == "2026-09-27T06:58:00Z")
            #expect(body?["body"] == nil)
            json = #"{"data":{"status":{"id":8002},"points":{"points":18},"alsoOnThisConnection":[]}}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private final class ZusatzhaltCheckinProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        let body = Self.body(of: request)
        let json: String
        switch true {
        case path.contains("autocomplete") && path.contains("Hanau"):
            // `findDeparture`'s distance check needs a coordinate on the candidate too, not just on
            // the `Station` being searched for — close to `hanau`'s own coordinate in the test leg.
            json = #"{"data":[{"id":555,"name":"Hanau Hbf","latitude":50.1066,"longitude":8.9166}]}"#
        case path.contains("autocomplete"):
            json = #"{"data":[{"id":901,"name":"Frankfurt (Main) Süd"}]}"#
        case path == "/api/v1/trips":
            json = #"{"data":{"tripId":"hop-trip","lineName":"ICE 372","origin":{"id":901},"destination":{"id":555}}}"#
        case path.contains("/departures"):
            json = """
            {"data":[{"tripId":"main-trip","plannedWhen":"2026-09-22T11:30:00Z",
                      "line":{"name":"ICE 372","fahrtNr":"372"},"direction":"Berlin Hbf",
                      "station":{"id":555,"name":"Hanau Hbf"}}]}
            """
        case path == "/api/v1/trains/trip":
            json = """
            {"data":{"id":1,"lineName":"ICE 372","stopovers":[
                {"id":555,"name":"Hanau Hbf","station":{"id":555,"name":"Hanau Hbf"},"departurePlanned":"2026-09-22T11:30:00Z"},
                {"id":777,"name":"Berlin Hbf","station":{"id":777,"name":"Berlin Hbf"},"arrivalPlanned":"2026-09-24T21:46:40Z"}
            ]}}
            """
        case path == "/api/v1/trains/checkin" && body?["tripId"] as? String == "hop-trip":
            json = #"{"data":{"status":{"id":9001},"points":{"points":5},"alsoOnThisConnection":[]}}"#
        case path == "/api/v1/trains/checkin":
            json = #"{"data":{"status":{"id":9002},"points":{"points":42},"alsoOnThisConnection":[{"id":1},{"id":2}]}}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private final class OAuthTokenRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        #expect(request.url?.absoluteString == "https://traewelling.de/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(data: body, encoding: .utf8)
        let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(parameters == [
            "grant_type": "authorization_code",
            "client_id": "public-client",
            "redirect_uri": "https://betterbahn.kunibert88.workers.dev/oauth/traewelling/callback",
            "code_verifier": "test-verifier",
            "code": "test-code",
        ])
        #expect(parameters["client_secret"] == nil)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class StatusUpdateRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        #expect(request.url?.absoluteString == "https://traewelling.de/api/v1/status/42")
        #expect(request.httpMethod == "PUT")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["manualDeparture"] as? String == "2023-11-14T22:13:20Z")
        #expect(json?["manual_departure"] as? String == "2023-11-14T22:13:20Z")
        #expect(json?["manualArrival"] as? String == "2023-11-14T23:13:20Z")
        #expect(json?["manual_arrival"] as? String == "2023-11-14T23:13:20Z")
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let statusJSON = """
        {"data":{"id":101,"createdAt":"2026-09-10T08:00:00+00:00","checkin":{"trip":5,"category":"nationalExpress","lineName":"ICE 645","journeyNumber":645,"distance":290000,"duration":160,"manualDeparture":null,"manualArrival":null,
        "origin":{"name":"Köln Hbf","station":{"id":1,"name":"Köln Hbf","latitude":50.943,"longitude":6.958},"departurePlanned":"2026-09-10T08:12:00+00:00","departureReal":"2026-09-10T08:16:00+00:00"},
        "destination":{"name":"Hannover Hbf","station":{"id":2,"name":"Hannover Hbf","latitude":52.376,"longitude":9.741},"arrivalPlanned":"2026-09-10T10:54:00+00:00","arrivalReal":null}}}}
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(statusJSON.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
