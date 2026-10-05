import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

/// Trains coupled under two numbers ("Doppeltraktion"), e.g. ICE 940 + ICE 950 from Berlin to Hamm.
@Suite(.serialized) struct CoupledTrainTests {
    let ice950 = Line(name: "ICE 950", number: "950", product: .highSpeed, operatorName: "DB Fernverkehr AG")

    @Test func displayNameListsCoupledTrainsLowestFirst() {
        var line = ice950
        #expect(line.displayName == "ICE 950")
        line.coupledTrains = [.init(name: "ICE 940", direction: "Düsseldorf Hbf")]
        #expect(line.displayName == "ICE 940 / 950")
        line.coupledTrains = [.init(name: "IC 2048", direction: nil)]
        #expect(line.displayName == "IC 2048 / ICE 950")
    }

    @Test func linesSavedBeforeCoupledNamesStillDecode() throws {
        let json = #"{"name": "ICE 950", "number": "950", "product": "highSpeed"}"#
        let line = try JSONDecoder().decode(Line.self, from: Data(json.utf8))
        #expect(line.coupledTrains == nil)
        #expect(line.displayName == "ICE 950")
    }

    @Test func coupledTrainNumbersMatchReservationsAndSearches() {
        var line = ice950
        line.coupledTrains = [.init(name: "ICE 940", direction: "Düsseldorf Hbf")]
        #expect(DBShareImporter.matches("ICE 940", line))
        #expect(TrainRoutePlanner.matches("ice940", line))
        #expect(!DBShareImporter.matches("ICE 941", line))
    }

    /// The plan names both places the coupled trains go on to, and checking in picks one of them.
    @Test func legCanBeRiddenAsTheCoupledTrain() throws {
        var leg = try leg()
        leg.line?.coupledTrains = [.init(name: "ICE 940", direction: "Düsseldorf Hbf")]
        #expect(leg.directionDescription == "Köln Hbf / Düsseldorf Hbf")

        let ice940 = leg.riding(.init(name: "ICE 940", direction: "Düsseldorf Hbf"))
        #expect(ice940.line?.name == "ICE 940")
        #expect(ice940.line?.number == "940")
        #expect(ice940.direction == "Düsseldorf Hbf")
        #expect(ice940.line?.coupledTrains == [.init(name: "ICE 950", direction: "Köln Hbf")])
        #expect(ice940.line?.displayName == "ICE 940 / 950")
    }

    /// bahn.de lists both halves; for a coupled leg both trainsets are the train ridden.
    @Test func formationOfACoupledLegNamesBothTrainsets() throws {
        let json = #"""
        {"groups": [
            {"name": "ICE9228", "transport": {"category": "ICE", "number": 946}, "vehicles": []},
            {"name": "ICE9203", "transport": {"category": "ICE", "number": 956}, "vehicles": []}
        ]}
        """#
        let response = try JSONDecoding.decoder.decode(BahnDeClient.SequenceResponse.self, from: Data(json.utf8))
        #expect(BahnDeClient.formation(from: response, category: "ICE", number: 946).unitSummary == "Tz 9228")
        let both = BahnDeClient.coachSequence(from: response, category: "ICE", number: 946, coupledNumbers: [956])
        #expect(both.formation.unitSummary == "Tz 9228 + 9203")
        #expect(both.groups.map(\.isRequestedTrain) == [true, true])

        var line = Line(name: "ICE 946", number: "946", product: .highSpeed, operatorName: nil)
        line.coupledTrains = [.init(name: "ICE 956", direction: "Köln Hbf")]
        #expect(line.coupledNumbers == ["956"])
    }

    func entry(_ name: String, number: String, otherEnd: String, platform: String = "5", minute: Int = 11,
               live: Bool = false) -> BoardEntry {
        let planned = Date(timeIntervalSince1970: 1_790_000_000 + Double(minute * 60))
        return BoardEntry(kind: .departures, tripId: name, station: station("hamm", "Hamm (Westf) Hbf", source: .transitous),
                          line: Line(name: name, number: number, product: .highSpeed, operatorName: nil),
                          otherEnd: otherEnd, time: TimeInfo(planned: planned, actual: live ? planned.addingTimeInterval(120) : nil),
                          platform: PlatformInfo(planned: platform, actual: nil), cancelled: false,
                          terminatesOrOriginatesHere: false, remarks: [], source: .transitous)
    }

    /// Hamm: ICE 941 and ICE 951 leave together for Berlin – one row.
    @Test func boardCombinesTrainsLeavingTogether() {
        let combined = TransitousProvider.combiningCoupledTrains([
            entry("ICE 941", number: "941", otherEnd: "Berlin Hbf"),
            entry("ICE 951", number: "951", otherEnd: "Berlin Hbf", live: true),
        ])
        #expect(combined.count == 1)
        // The live row leads, so its delay shows.
        #expect(combined.first?.tripId == "ICE 951")
        #expect(combined.first?.line.displayName == "ICE 941 / 951")
    }

    /// Berlin: ICE 940 and ICE 950 leave together but split in Hamm for Düsseldorf and Köln; other
    /// platforms or minutes are other trains.
    @Test func boardKeepsTrainsThatSplitOrDiffer() {
        #expect(TransitousProvider.combiningCoupledTrains([
            entry("ICE 940", number: "940", otherEnd: "Düsseldorf Hbf"),
            entry("ICE 950", number: "950", otherEnd: "Köln Hbf"),
        ]).count == 2)
        #expect(TransitousProvider.combiningCoupledTrains([
            entry("ICE 941", number: "941", otherEnd: "Berlin Hbf", platform: "5"),
            entry("ICE 951", number: "951", otherEnd: "Berlin Hbf", platform: "9"),
        ]).count == 2)
        #expect(TransitousProvider.combiningCoupledTrains([
            entry("ICE 941", number: "941", otherEnd: "Berlin Hbf", minute: 11),
            entry("ICE 951", number: "951", otherEnd: "Berlin Hbf", minute: 13),
        ]).count == 2)
    }

    func leg() throws -> Leg {
        Leg(origin: station("berlin", "Berlin Hbf", source: .transitous),
            destination: station("hamm", "Hamm (Westf) Hbf", source: .transitous),
            departure: TimeInfo(planned: try #require(JSONDecoding.parseISODate("2026-10-05T08:39:00Z")), actual: nil),
            arrival: TimeInfo(planned: try #require(JSONDecoding.parseISODate("2026-10-05T12:49:00Z")), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: "trip-950", line: ice950, direction: "Köln Hbf",
            isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    func provider(_ protocolClass: URLProtocol.Type) -> (TransitousProvider, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let session = URLSession(configuration: config)
        return (TransitousProvider(http: HTTPClient(session: session)), session)
    }

    /// Transitous routes Berlin → Hamm over ICE 950 only; ICE 940 arrives with it and left Berlin with it.
    @Test func journeyLegFindsTheTrainCoupledAllTheWay() async throws {
        HammArrivalsProtocol.ice940Origin.withLock { $0 = ("berlin", "Berlin Hbf", "2026-10-05T08:39:00Z") }
        let (provider, session) = provider(HammArrivalsProtocol.self)
        defer { session.invalidateAndCancel() }
        let leg = try leg()

        let coupled = await provider.coupledTrains(for: [leg])

        #expect(coupled[leg.id] == [.init(name: "ICE 940", direction: "Düsseldorf Hbf")])
        let journeys = CombinedProvider.applying(coupled, to: [Journey(legs: [leg], source: .transitous)])
        #expect(journeys.first?.legs.first?.line?.displayName == "ICE 940 / 950")
    }

    /// The same arrival, but ICE 940 came from Hamburg and was only coupled on the way: riding from
    /// Berlin, only ICE 950 gets you there.
    @Test func journeyLegIgnoresATrainJoinedOnTheWay() async throws {
        HammArrivalsProtocol.ice940Origin.withLock { $0 = ("hamburg", "Hamburg Hbf", "2026-10-05T08:39:00Z") }
        let (provider, session) = provider(HammArrivalsProtocol.self)
        defer { session.invalidateAndCancel() }
        let leg = try leg()

        #expect(await provider.coupledTrains(for: [leg]).isEmpty)
    }
}

/// Arrivals at Hamm at 12:49 (ICE 940 and ICE 950 on track 10, ICE 951 later on track 5) and ICE
/// 940's trip, starting where `ice940Origin` says.
private final class HammArrivalsProtocol: URLProtocol, @unchecked Sendable {
    static let ice940Origin = Mutex<(id: String, name: String, departure: String)>(("berlin", "Berlin Hbf", "2026-10-05T08:39:00Z"))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        if path.hasSuffix("v5/stoptimes") {
            body = """
            {"stopTimes": [
                {"place": {"name": "Hamm (Westf) Hbf", "stopId": "hamm:10", "parentId": "hamm", "lat": 51.67, "lon": 7.81,
                           "scheduledArrival": "2026-10-05T12:49:00Z", "scheduledTrack": "10"},
                 "mode": "HIGHSPEED_RAIL", "tripId": "trip-940", "displayName": "ICE 940", "tripShortName": "ICE 940"},
                {"place": {"name": "Hamm (Westf) Hbf", "stopId": "hamm:10", "parentId": "hamm", "lat": 51.67, "lon": 7.81,
                           "scheduledArrival": "2026-10-05T12:49:00Z", "scheduledTrack": "10"},
                 "mode": "HIGHSPEED_RAIL", "tripId": "trip-950", "displayName": "ICE 950", "tripShortName": "ICE 950"},
                {"place": {"name": "Hamm (Westf) Hbf", "stopId": "hamm:5", "parentId": "hamm", "lat": 51.67, "lon": 7.81,
                           "scheduledArrival": "2026-10-05T13:02:00Z", "scheduledTrack": "5"},
                 "mode": "HIGHSPEED_RAIL", "tripId": "trip-951", "displayName": "ICE 951", "tripShortName": "ICE 951"}
            ]}
            """
        } else {
            let origin = Self.ice940Origin.withLock { $0 }
            body = """
            {"legs": [{"mode": "HIGHSPEED_RAIL",
                "from": {"name": "\(origin.name)", "stopId": "\(origin.id):7", "parentId": "\(origin.id)", "lat": 53.55, "lon": 10.0,
                         "scheduledDeparture": "\(origin.departure)", "departure": "\(origin.departure)"},
                "to": {"name": "Düsseldorf Hbf", "stopId": "dus:15", "parentId": "dus", "lat": 51.22, "lon": 6.79,
                       "scheduledArrival": "2026-10-05T14:10:00Z", "arrival": "2026-10-05T14:10:00Z"},
                "startTime": "\(origin.departure)", "endTime": "2026-10-05T14:10:00Z",
                "tripId": "trip-940", "displayName": "ICE 940", "tripShortName": "ICE 940", "headsign": "Düsseldorf Hbf"}]}
            """
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
