import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// Who of the people the user follows is on a train right now (#196).
@Suite struct TraewellingFollowedTests {
    /// 2026-10-06 11:00 UTC.
    static let now = ISO8601DateFormatter().date(from: "2026-10-06T11:00:00Z")!

    /// A check-in by `user` from `from` to `to` (minutes after 10:00 UTC); `delay` minutes late at the exit.
    static func json(id: Int, user: Int?, from: Int, to: Int, delay: Int = 0, hafasId: String = "20261006_10_ab12",
                     extra: String = "") -> String {
        func time(_ minutes: Int) -> String { String(format: "2026-10-06T%02d:%02d:00+00:00", 10 + minutes / 60, minutes % 60) }
        let userJSON = user.map { #""user":{"id":\#($0),"displayName":"User \#($0)","username":"user\#($0)"},"# } ?? ""
        return """
        {"id":\(id),\(userJSON)\(extra)
         "checkin":{"trip":99,"hafasId":"\(hafasId)","lineName":"RE 1","journeyNumber":4711,
          "origin":{"name":"B","station":{"id":1,"name":"B","latitude":52.0,"longitude":13.0},
                    "departurePlanned":"\(time(from))","departureReal":"\(time(from))"},
          "destination":{"name":"C","station":{"id":2,"name":"C","latitude":52.5,"longitude":13.5},
                         "arrivalPlanned":"\(time(to))","arrivalReal":"\(time(to + delay))"}}}
        """
    }

    static func status(id: Int, user: Int?, from: Int, to: Int, delay: Int = 0, hafasId: String = "20261006_10_ab12",
                       extra: String = "") throws -> TraewellingStatus {
        try JSONDecoding.decoder.decode(TraewellingStatus.self, from: Data(json(id: id, user: user, from: from, to: to, delay: delay,
                                                                             hafasId: hafasId, extra: extra).utf8))
    }

    @Test func decodesLikesAndTags() throws {
        let status = try Self.status(id: 1, user: 11, from: 0, to: 90, extra: """
        "likes":3,"liked":true,"isLikable":false,
        "tags":[{"key":"trwl:seat","value":"61","visibility":0},{"key":"trwl:wagon","value":"7","visibility":0}],
        """)
        #expect(status.likes == 3)
        #expect(status.liked == true)
        #expect(status.isLikable == false)
        #expect(status.tags.map(\.value) == ["61", "7"])
        #expect(!status.checkin.isManualTrip)
    }

    @Test func readsTheAuthorsMastodonInstance() throws {
        func user(_ mastodon: String) throws -> TraewellingStatus.User? {
            try JSONDecoding.decoder.decode(TraewellingStatus.self, from: Data(#"""
            {"id":1,"user":{"id":11,"displayName":"A","username":"a","mastodon":\#(mastodon)},
             "checkin":{"origin":{"name":"A"},"destination":{"name":"B"}}}
            """#.utf8)).user
        }
        #expect(try user(#"{"server":"Chaos.Social","user_id":"1"}"#)?.mastodonServer == "chaos.social")
        #expect(try user(#"{"server":null,"user_id":null}"#)?.mastodonServer == nil)
        // Something unexpected there must not lose the user.
        #expect(try user(#""nope""#)?.username == "a")
    }

    @Test func brokenTagsDontHideTheCheckin() throws {
        let status = try Self.status(id: 1, user: 11, from: 0, to: 90, extra: #""tags":"nope","#)
        #expect(status.tags.isEmpty)
        #expect(status.likes == nil)
    }

    @Test func tripTypedInOnTraewellingIsManual() throws {
        let status = try Self.status(id: 1, user: 11, from: 0, to: 90, hafasId: "0b6f1b3e-6c1f-4f5e-9d0e-3a7f2b9c8d11")
        #expect(status.checkin.isManualTrip)
    }

    @Test func keepsOthersRidesUnderWayOrLeavingSoon() throws {
        let statuses = [
            try Self.status(id: 1, user: 11, from: 30, to: 90),            // under way
            try Self.status(id: 2, user: 10, from: 30, to: 90),            // my own
            try Self.status(id: 3, user: 12, from: 0, to: 50),             // already there
            try Self.status(id: 4, user: 13, from: 0, to: 50, delay: 20),  // there at 11:10 because of the delay
            try Self.status(id: 5, user: 14, from: 75, to: 120),           // waiting for the train at 11:15
            try Self.status(id: 8, user: 16, from: 90, to: 120),           // leaves at 11:30, too far off
            try Self.status(id: 6, user: nil, from: 30, to: 90),           // can't tell whose
            try Self.status(id: 1, user: 11, from: 30, to: 90),            // twice on the dashboard
            try Self.status(id: 7, user: 15, from: 45, to: 90),
        ]
        let checkedIn = TraewellingClient.checkedIn(statuses, excludingUser: 10, at: Self.now)
        // Latest departure first.
        #expect(checkedIn.map(\.id) == [5, 7, 1, 4])
    }

    @Test func aDelayDoesntHideSomeoneWaitingForTheTrain() throws {
        // Planned at 11:15, but leaving only at 11:45.
        let late = try JSONDecoding.decoder.decode(TraewellingStatus.self, from: Data(#"""
        {"id":9,"user":{"id":17,"displayName":"U","username":"u"},
         "checkin":{"origin":{"name":"B","departurePlanned":"2026-10-06T11:15:00+00:00","departureReal":"2026-10-06T11:45:00+00:00"},
                    "destination":{"name":"C","arrivalPlanned":"2026-10-06T12:00:00+00:00"}}}
        """#.utf8))
        #expect(TraewellingClient.checkedIn([late], excludingUser: 10, at: Self.now).map(\.id) == [9])
    }

    @Test func findsTheTrainByNameOrRunNumber() throws {
        let status = try Self.status(id: 1, user: 11, from: 30, to: 60)
        let planned = try #require(status.checkin.origin.departurePlanned)
        func entry(_ name: String, number: String?, trip: String?, at minutes: Double) -> BoardEntry {
            BoardEntry(kind: .departures, tripId: name + "\(minutes)", station: station("b", "B"),
                       line: Line(name: name, number: number, product: .regional, operatorName: nil, tripNumber: trip),
                       otherEnd: nil, time: TimeInfo(planned: planned.addingTimeInterval(minutes * 60), actual: nil),
                       platform: PlatformInfo(planned: nil, actual: nil), cancelled: false,
                       terminatesOrOriginatesHere: nil, remarks: [], source: .transitous)
        }
        let entries = [
            entry("RE 1", number: "1", trip: "4711", at: 0),
            entry("RB 2", number: "2", trip: "8000", at: 0),      // other train at the same time
            entry("RE 1", number: "1", trip: "4713", at: 60),     // the next RE 1
            entry("RE 10", number: "10", trip: "4711", at: 1),    // other name, same run number
        ]
        let found = CombinedProvider.candidates(for: status, departingAt: planned, in: entries)
        #expect(found.map(\.line.name) == ["RE 1", "RE 10"])
    }

    @Test func cutsTheRideOutOfTheTrain() throws {
        let status = try Self.status(id: 1, user: 11, from: 30, to: 60)
        let ride = try #require(status.journey(geometry: nil)?.legs.first)
        func stop(_ name: String, _ lat: Double, _ lon: Double, at minutes: Double) -> Stopover {
            let time = TimeInfo(planned: ride.departure.planned.addingTimeInterval((minutes - 30) * 60), actual: nil)
            return Stopover(station: station(name, name, lat, lon, source: .transitous), arrival: time, departure: time,
                            arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let trip = Trip(id: "re1-4711", line: Line(name: "RE 1", number: "1", product: .regional, operatorName: nil),
                        direction: "D", stopovers: [stop("A", 51.5, 12.5, at: 0), stop("B", 52.0, 13.0, at: 30),
                                                    stop("X", 52.2, 13.2, at: 45),
                                                    // The feed's name differs and its stop lies 1 km off.
                                                    stop("C-Stadt", 52.509, 13.5, at: 60), stop("D", 53.0, 14.0, at: 90)],
                        cancelled: false, remarks: [], source: .transitous)
        let leg = try #require(CombinedProvider.leg(of: trip, riding: ride))
        #expect(leg.tripId == "re1-4711")
        #expect(leg.stopovers.map(\.station.name) == ["B", "X", "C-Stadt"])
    }

    @Test func noTrainForManualTrips() async throws {
        let provider = CombinedProvider(bahnDe: nil, bahnExpert: nil, vagonweb: nil, bahnJetzt: nil)
        let status = try Self.status(id: 1, user: 11, from: 30, to: 60, hafasId: "0b6f1b3e-6c1f-4f5e-9d0e-3a7f2b9c8d11")
        #expect(try await provider.leg(forCheckin: status) == nil)
    }
}

@Suite(.serialized) struct TraewellingFollowedRequestTests {
    @Test func loadsTheDashboardAndLikesSetting() async throws {
        let (client, store) = client()
        defer { store.clear() }
        FollowedProtocol.reset(statusFor: { _ in 200 })

        let followed = try await client.followedCheckins(at: TraewellingFollowedTests.now)

        #expect(FollowedProtocol.requests.withLock { $0 } == ["GET /api/v1/auth/user", "GET /api/v1/dashboard?page=1"])
        #expect(followed.statuses.map(\.id) == [2])
        #expect(!followed.likesEnabled)
    }

    @Test func likesAndUnlikes() async throws {
        let (client, store) = client()
        defer { store.clear() }
        FollowedProtocol.reset(statusFor: { $0.hasPrefix("POST") ? 201 : 200 })

        #expect(try await client.like(statusId: 7) == 3)
        #expect(try await client.unlike(statusId: 7) == 3)
        #expect(FollowedProtocol.requests.withLock { $0 } == ["POST /api/v1/status/7/like", "DELETE /api/v1/status/7/like"])
    }

    @Test func likingTwiceOrUnlikingAgainIsFine() async throws {
        let (client, store) = client()
        defer { store.clear() }
        FollowedProtocol.reset(statusFor: { $0.hasPrefix("POST") ? 409 : 404 })

        #expect(try await client.like(statusId: 7) == nil)
        #expect(try await client.unlike(statusId: 7) == nil)
    }

    @Test func refusedLikeAsksToLogInAgain() async throws {
        let (client, store) = client()
        defer { store.clear() }
        FollowedProtocol.reset(statusFor: { _ in 403 })

        await #expect(throws: TraewellingError.likeNotAllowed) { try await client.like(statusId: 7) }
    }

    private func client() -> (TraewellingClient, TokenStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FollowedProtocol.self]
        let store = TokenStore(service: "BetterBahnKitTests.\(UUID().uuidString)")
        store.save(OAuthToken(accessToken: "test-token", refreshToken: nil, expiresAt: .distantFuture))
        let client = TraewellingClient(config: TraewellingConfig(clientID: "public-client"),
                                       http: HTTPClient(session: URLSession(configuration: configuration)), store: store)
        return (client, store)
    }
}

/// Records "METHOD /path?query" and answers with the given status: the user (likes off), a dashboard
/// page with the user's own and a followed user's check-in on a train, or a like count.
private final class FollowedProtocol: URLProtocol, @unchecked Sendable {
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
        let query = url.query(percentEncoded: false).map { "?" + $0 } ?? ""
        let entry = "\(request.httpMethod ?? "GET") \(url.path(percentEncoded: false))\(query)"
        Self.requests.withLock { $0.append(entry) }
        let status = Self.statusFor(entry)
        let body: String
        if !(200..<300).contains(status) {
            body = #"{"message":"Nope"}"#
        } else if entry.hasSuffix("/auth/user") {
            body = #"{"data":{"id":10,"displayName":"Me","username":"me","likes_enabled":false}}"#
        } else if entry.contains("/dashboard") {
            let statuses = [TraewellingFollowedTests.json(id: 1, user: 10, from: 30, to: 90),
                            TraewellingFollowedTests.json(id: 2, user: 11, from: 30, to: 90)]
            body = #"{"data":["# + statuses.joined(separator: ",") + #"],"links":{"next":null}}"#
        } else {
            body = #"{"data":{"count":3}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
