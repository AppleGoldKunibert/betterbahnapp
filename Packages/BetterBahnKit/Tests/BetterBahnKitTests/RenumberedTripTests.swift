import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// Transitous' trip IDs change when a feed is imported again, so a saved journey's leg can point at a
/// run that is gone (404, "Serverfehler (404)" when opening ICE 2074's stops).
@Suite(.serialized) struct RenumberedTripTests {
    let ice2074 = Line(name: "ICE 2074", number: "2074", product: .highSpeed, operatorName: "DB Fernverkehr AG")

    func leg(tripId: String = "old-2074") throws -> Leg {
        Leg(origin: station("berlin", "Berlin Gesundbrunnen", source: .transitous),
            destination: station("hamburg", "Hamburg Hbf", source: .transitous),
            departure: TimeInfo(planned: try #require(JSONDecoding.parseISODate("2026-10-06T06:09:00Z")), actual: nil),
            arrival: TimeInfo(planned: try #require(JSONDecoding.parseISODate("2026-10-06T08:14:00Z")), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: tripId, line: ice2074, direction: "Westerland(Sylt)",
            isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    func provider() -> (CombinedProvider, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RenumberedTripProtocol.self]
        let session = URLSession(configuration: config)
        let transitous = TransitousProvider(http: HTTPClient(session: session))
        return (CombinedProvider(primary: transitous, bahnDe: nil, bahnExpert: nil, vagonweb: nil, bahnJetzt: nil), session)
    }

    @Test func goneTripIsFoundAgainOnTheOriginsBoard() async throws {
        RenumberedTripProtocol.tripRequests.withLock { $0 = [] }
        let (combined, session) = provider()
        defer { session.invalidateAndCancel() }

        let trip = try await combined.trip(for: try leg())
        #expect(trip.id == "new-2074")
        #expect(trip.line?.name == "ICE 2074")

        // Remembered: the next lookup goes straight to the new run.
        _ = try await combined.trip(for: try leg())
        #expect(RenumberedTripProtocol.tripRequests.withLock { $0 }.filter { $0 == "old-2074" }.count == 1)
    }

    @Test func refreshKeepsTheLegsOwnTripId() async throws {
        let (combined, session) = provider()
        defer { session.invalidateAndCancel() }
        let leg = try leg()
        let journey = Journey(legs: [leg], source: .transitous)

        // While the train runs: once it's long over, the leg keeps what it had and isn't refreshed.
        let refreshed = await JourneyRefresher(provider: combined).refreshEnds(journey, now: leg.departure.planned)

        #expect(refreshed.legs.first?.tripId == "old-2074")
        #expect(refreshed.legs.first?.departurePlatform?.best == "6")
    }

    @Test func otherTrainsAtTheSameTimeDontMatch() throws {
        var other = try leg()
        other.line = Line(name: "RE 5", number: "5", product: .regional, operatorName: nil, tripNumber: "2074")
        let entry = BoardEntry(kind: .departures, tripId: "new-2074", station: other.origin, line: ice2074, otherEnd: nil,
                               time: other.departure, platform: PlatformInfo(planned: nil, actual: nil), cancelled: false,
                               terminatesOrOriginatesHere: nil, remarks: [], source: .transitous)
        #expect(CombinedProvider.sameTrain(as: other, in: [entry]) == nil)
        #expect(CombinedProvider.sameTrain(as: try leg(), in: [entry])?.tripId == "new-2074")
    }

    /// A train Transitous no longer has at all (long past) shows the leg's saved stops instead.
    @Test func savedTripIsTheLegsOwnStops() throws {
        var leg = try leg()
        let ends = try #require(leg.savedTrip)
        #expect(ends.stopovers.map(\.station.name) == ["Berlin Gesundbrunnen", "Hamburg Hbf"])
        #expect(ends.stopovers.first?.departure == leg.departure)
        #expect(ends.stopovers.last?.arrival == leg.arrival)
        #expect(ends.id == "old-2074")

        let spandau = Stopover(station: station("spandau", "Berlin-Spandau", source: .transitous),
                               arrival: leg.departure, departure: leg.departure,
                               arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        leg.stopovers = [ends.stopovers[0], spandau, ends.stopovers[1]]
        #expect(leg.savedTrip?.stopovers.map(\.station.name) == ["Berlin Gesundbrunnen", "Berlin-Spandau", "Hamburg Hbf"])

        leg.isWalking = true
        #expect(leg.savedTrip == nil)
    }

    @Test func unknownTripStillFailsWhenTheBoardHasNoSuchTrain() async throws {
        let (combined, session) = provider()
        defer { session.invalidateAndCancel() }
        var leg = try leg()
        leg.line = Line(name: "ICE 9999", number: "9999", product: .highSpeed, operatorName: nil)

        await #expect(throws: TransitError.self) { try await combined.trip(for: leg) }
    }
}

/// `old-2074` is gone (404); the board at Berlin Gesundbrunnen lists ICE 2074 as `new-2074`.
private final class RenumberedTripProtocol: URLProtocol, @unchecked Sendable {
    static let tripRequests = Mutex<[String]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var status = 200
        let body: String
        if url.path.hasSuffix("v5/stoptimes") {
            body = """
            {"stopTimes": [
                {"place": {"name": "Berlin Gesundbrunnen", "stopId": "berlin:6", "parentId": "berlin", "lat": 52.55, "lon": 13.39,
                           "scheduledDeparture": "2026-10-06T06:09:00Z", "scheduledTrack": "6"},
                 "mode": "HIGHSPEED_RAIL", "tripId": "new-2074", "displayName": "ICE 2074", "tripShortName": "ICE 2074",
                 "headsign": "Westerland(Sylt)"}
            ]}
            """
        } else if url.path.hasSuffix("v5/trip") {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tripId" }?.value ?? ""
            Self.tripRequests.withLock { $0.append(id) }
            if id == "new-2074" {
                body = """
                {"legs": [{"mode": "HIGHSPEED_RAIL",
                    "from": {"name": "Berlin Gesundbrunnen", "stopId": "berlin:6", "parentId": "berlin", "lat": 52.55, "lon": 13.39,
                             "scheduledDeparture": "2026-10-06T06:09:00Z", "departure": "2026-10-06T06:09:00Z", "scheduledTrack": "6"},
                    "to": {"name": "Hamburg Hbf", "stopId": "hamburg:11", "parentId": "hamburg", "lat": 53.55, "lon": 10.0,
                           "scheduledArrival": "2026-10-06T08:14:00Z", "arrival": "2026-10-06T08:14:00Z"},
                    "startTime": "2026-10-06T06:09:00Z", "endTime": "2026-10-06T08:14:00Z",
                    "tripId": "new-2074", "displayName": "ICE 2074", "tripShortName": "ICE 2074", "headsign": "Westerland(Sylt)"}]}
                """
            } else {
                status = 404
                body = #"{"error": "trip not found"}"#
            }
        } else {
            body = "[]"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
