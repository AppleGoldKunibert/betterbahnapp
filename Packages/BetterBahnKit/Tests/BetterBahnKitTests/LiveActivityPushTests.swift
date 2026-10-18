import Foundation
import Testing
@testable import BetterBahnKit

/// The Live Activity's state while the app is closed (#315): the `betterbahn-live` Worker works it out from what
/// the app sends (`LiveActivityPushJourney`) with its own copy of `ContentState.from(_:)` (`state.mjs`). Both
/// check `Fixtures/live-activity-push.json`: here that the app sends that journey and shows those states, in
/// `Cloudflare/live-activity/worker.test.mjs` that the Worker works out the same states from it.
@Suite struct LiveActivityPushTests {
    struct Fixture: Decodable {
        struct Scenario: Decodable {
            var name: String
            var journey: LiveActivityPushJourney
            var cases: [Case]
        }

        struct Case: Decodable {
            var now: Double
            var state: TripActivityAttributes.ContentState
        }

        var scenarios: [Scenario]
    }

    private func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "live-activity-push", withExtension: "json", subdirectory: "Fixtures"))
        // ActivityKit decodes a pushed state as a plain `JSONDecoder` does: dates as seconds since 2001.
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private let t0 = Date(timeIntervalSince1970: 1_792_231_200) // 2026-10-17 12:00 in Germany
    private func m(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func station(_ eva: String?, _ name: String) -> Station {
        Station(id: eva ?? name, name: name, coordinate: nil, evaNumber: eva, source: eva == nil ? .transitous : .bahnDe)
    }

    private var nord: Station { station("1000001", "Teststadt Nord") }
    private var mitte: Station { station("1000002", "Teststadt Mitte") }
    private var testau: Station { station("1000003", "Testau") }
    private var testdorf: Station { station("1000004", "Testdorf") }
    private var hafen: Station { station(nil, "Testhafen") }

    private func leg(_ line: Line?, _ origin: Station, _ destination: Station, departure: TimeInfo, arrival: TimeInfo,
                     departurePlatform: PlatformInfo? = nil, arrivalPlatform: PlatformInfo? = nil, cancelled: Bool = false,
                     stopovers: [Stopover] = []) -> Leg {
        Leg(origin: origin, destination: destination, departure: departure, arrival: arrival,
            departurePlatform: departurePlatform, arrivalPlatform: arrivalPlatform, tripId: line.map { "trip-\($0.name)" },
            line: line, direction: nil, isWalking: line == nil, cancelled: cancelled, stopovers: stopovers, remarks: [],
            source: .bahnDe)
    }

    /// ICE 571 three minutes late (platform 9 instead of 7), five at Testau, four at Teststadt Mitte; a walk; RE 3 on to Testhafen.
    private var transfer: Journey {
        let ice = Line(name: "ICE 571", number: "571", product: .highSpeed, operatorName: nil)
        let re = Line(name: "RE 3", number: "3", product: .regionalExpress, operatorName: nil, tripNumber: "3312")
        return Journey(legs: [
            leg(ice, nord, mitte, departure: TimeInfo(planned: m(0), actual: m(3)), arrival: TimeInfo(planned: m(60), actual: m(64)),
                departurePlatform: PlatformInfo(planned: "7", actual: "9"), arrivalPlatform: PlatformInfo(planned: "3", actual: nil),
                stopovers: [
                    Stopover(station: nord, arrival: nil, departure: TimeInfo(planned: m(0), actual: m(3)),
                             arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
                    Stopover(station: testau, arrival: TimeInfo(planned: m(30), actual: m(35)), departure: TimeInfo(planned: m(31), actual: m(36)),
                             arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
                    Stopover(station: mitte, arrival: TimeInfo(planned: m(60), actual: m(64)), departure: nil,
                             arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
                ]),
            leg(nil, mitte, mitte, departure: TimeInfo(planned: m(64), actual: nil), arrival: TimeInfo(planned: m(66), actual: nil)),
            leg(re, mitte, hafen, departure: TimeInfo(planned: m(70), actual: nil), arrival: TimeInfo(planned: m(100), actual: nil),
                departurePlatform: PlatformInfo(planned: "12", actual: nil)),
        ], source: .bahnDe)
    }

    /// NJ 421 twelve minutes late, so RB 12 (moved to platform 5) leaves before it arrives.
    private var missedTransfer: Journey {
        Journey(legs: [
            leg(Line(name: "NJ 421", number: "421", product: .longDistance, operatorName: nil), nord, mitte,
                departure: TimeInfo(planned: m(0), actual: m(0)), arrival: TimeInfo(planned: m(60), actual: m(72))),
            leg(Line(name: "RB 12", number: "12", product: .regional, operatorName: nil), mitte, hafen,
                departure: TimeInfo(planned: m(70), actual: nil), arrival: TimeInfo(planned: m(100), actual: nil),
                departurePlatform: PlatformInfo(planned: "2", actual: "5")),
        ], source: .bahnDe)
    }

    private var cancelled: Journey {
        Journey(legs: [
            leg(Line(name: "S 1", number: "1", product: .suburban, operatorName: nil), testdorf, hafen,
                departure: TimeInfo(planned: m(0), actual: nil), arrival: TimeInfo(planned: m(20), actual: nil), cancelled: true),
        ], source: .bahnDe)
    }

    @Test(arguments: ["transfer", "missedTransfer", "cancelled"])
    func workerShowsWhatTheAppShows(scenario name: String) throws {
        let scenario = try #require(try fixture().scenarios.first { $0.name == name })
        let journey = switch name {
        case "transfer": transfer
        case "missedTransfer": missedTransfer
        default: cancelled
        }
        #expect(LiveActivityPushJourney(journey, eva: { $0.evaNumber }) == scenario.journey)
        #expect(!scenario.cases.isEmpty)
        for testCase in scenario.cases {
            let state = TripActivityAttributes.ContentState.from(journey, now: Date(timeIntervalSince1970: testCase.now))
            #expect(state == testCase.state, "\(name) at \(testCase.now)")
        }
    }

    @Test func sendsOnlyTrainLegsWithWhatIRISKnowsThemBy() {
        let sent = LiveActivityPushJourney(transfer, eva: { $0.evaNumber })
        #expect(sent.legs.map(\.line) == ["ICE 571", "RE 3"])
        #expect(sent.legs[1].category == "RE")
        // A regional train goes by its run number in DB's feed, not its line.
        #expect(sent.legs[1].number == "3312")
        #expect(sent.legs[1].destinationEva == nil)
        // The stops after the start, so the first one is where the delay while riding comes from.
        #expect(sent.legs[0].stops.map(\.eva) == ["1000003", "1000002"])
        #expect(sent.legs[0].departure.actual == Int(m(3).timeIntervalSince1970))
    }

    @Test func leavesTrainsWithoutNumberToTheApp() {
        let bus = leg(Line(name: "Bus 100", number: nil, product: .bus, operatorName: nil), nord, mitte,
                      departure: TimeInfo(planned: m(0), actual: nil), arrival: TimeInfo(planned: m(10), actual: nil))
        let sent = LiveActivityPushJourney(Journey(legs: [bus], source: .transitous), eva: { $0.evaNumber })
        #expect(sent.legs[0].category == nil)
        #expect(sent.legs[0].number == nil)
    }
}

/// `LiveActivityPush` against a fake `betterbahn-live` Worker.
@Suite(.serialized) struct LiveActivityPushClientTests {
    private let push = LiveActivityPush(http: HTTPClient(session: LiveWorkerProtocol.session()), baseURL: LiveWorkerProtocol.base)
    private let registration = LiveActivityPushRegistration(id: "0123456789abcdef0123456789abcdef", secret: "s3cret", journeyID: "j1")

    private var journey: LiveActivityPushJourney {
        let leg = Leg(origin: Station(id: "8000105", name: "Frankfurt (Main) Hbf", coordinate: nil, evaNumber: "8000105", source: .bahnDe),
                      destination: Station(id: "8000261", name: "München Hbf", coordinate: nil, evaNumber: "8000261", source: .bahnDe),
                      departure: TimeInfo(planned: Date(timeIntervalSince1970: 1_792_231_200), actual: nil),
                      arrival: TimeInfo(planned: Date(timeIntervalSince1970: 1_792_242_000), actual: nil),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "t",
                      line: Line(name: "ICE 571", number: "571", product: .highSpeed, operatorName: nil),
                      direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
        return LiveActivityPushJourney(Journey(legs: [leg], source: .bahnDe), eva: { $0.evaNumber })
    }

    @Test func handsTheActivityOverWithItsPushTokenAndJourney() async throws {
        LiveWorkerProtocol.state = .init()
        try await push.register(registration, pushToken: "abcd", sandbox: true, journey: journey)
        let request = try #require(LiveWorkerProtocol.state.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/activities/0123456789abcdef0123456789abcdef")
        #expect(request.body["secret"] as? String == "s3cret")
        #expect(request.body["pushToken"] as? String == "abcd")
        #expect(request.body["sandbox"] as? Bool == true)
        let legs = (request.body["journey"] as? [String: Any])?["legs"] as? [[String: Any]]
        #expect(legs?.first?["line"] as? String == "ICE 571")
        #expect(legs?.first?["originEva"] as? String == "8000105")
        #expect((legs?.first?["departure"] as? [String: Any])?["planned"] as? Int == 1_792_231_200)

        LiveWorkerProtocol.state = .init(status: 503)
        await #expect(throws: TransitError.self) {
            try await push.register(registration, pushToken: "abcd", sandbox: true, journey: journey)
        }
    }

    @Test func takesItBackAndCountsAGoneOneAsTakenBack() async throws {
        LiveWorkerProtocol.state = .init()
        try await push.unregister(registration)
        #expect(LiveWorkerProtocol.state.requests.first?.method == "DELETE")
        #expect(LiveWorkerProtocol.state.requests.first?.body["secret"] as? String == "s3cret")
        LiveWorkerProtocol.state = .init(status: 404)
        try await push.unregister(registration)
    }

    @Test func makesUpARandomIDAndSecretTheWorkerAccepts() {
        let a = LiveActivityPushRegistration(journeyID: "j1"), b = LiveActivityPushRegistration(journeyID: "j1")
        #expect(a.id.count == 32 && a.secret.count == 64)
        #expect(a.id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(a.id != b.id && a.secret != b.secret)
        #expect(LiveActivityPush.hex(Data([0x0A, 0xFF])) == "0aff")
    }
}

/// The `betterbahn-live` Worker's stand-in: records each request and answers with `state.status`.
final class LiveWorkerProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://live.test")!

    struct Recorded: @unchecked Sendable {
        var method: String
        var path: String
        var body: [String: Any]
    }

    struct State: @unchecked Sendable {
        var status = 0
        var requests: [Recorded] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _state = State()
    static var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveWorkerProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        var status = Self.state.status
        Self.state.requests.append(Recorded(method: method, path: request.url?.path ?? "", body: body))
        if status == 0 { status = method == "DELETE" ? 204 : 200 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
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
