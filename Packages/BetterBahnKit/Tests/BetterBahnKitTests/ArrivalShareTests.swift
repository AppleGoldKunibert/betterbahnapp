import Foundation
import Testing
@testable import BetterBahnKit

/// "Ankunft teilen" (#317): what the pickup page gets from a journey.
@Suite struct ArrivalShareTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Hamburg → Berlin by ICE, then Berlin Hbf → Ostkreuz by S-Bahn, then a walk.
    private func journey() -> Journey {
        let ice = JourneyShareLinkTests.journey().legs[0]
        let ostkreuz = station("ostkreuz", "Berlin Ostkreuz", source: .transitous)
        let sBahn = Leg(origin: station("8011160", "Berlin Hbf"), destination: ostkreuz,
                        departure: TimeInfo(planned: start.addingTimeInterval(5 * 3600), actual: nil),
                        arrival: TimeInfo(planned: start.addingTimeInterval(5 * 3600 + 600), actual: start.addingTimeInterval(5 * 3600 + 780)),
                        departurePlatform: PlatformInfo(planned: "15", actual: nil),
                        arrivalPlatform: PlatformInfo(planned: "3", actual: "4"), tripId: "s",
                        line: Line(name: "S5", number: nil, product: .suburban, operatorName: "S-Bahn Berlin GmbH"),
                        direction: "Strausberg Nord", isWalking: false, cancelled: false, stopovers: [], remarks: [],
                        source: .transitous)
        let walk = Leg(origin: ostkreuz, destination: station("home", "Zuhause", source: .transitous),
                       departure: sBahn.arrival, arrival: TimeInfo(planned: sBahn.arrival.planned.addingTimeInterval(300), actual: nil),
                       departurePlatform: nil, arrivalPlatform: nil, tripId: nil, line: nil, direction: nil,
                       isWalking: true, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        return Journey(legs: [ice, sBahn, walk], source: .transitous)
    }

    @Test func sharesTheLastTrainNotTheWalk() throws {
        let journey = journey()
        #expect(ArrivalShare.stationsNeedingEVA(in: journey).map(\.id) == ["ostkreuz"])

        let share = try #require(ArrivalShare(journey: journey, journeyId: "2|#VN#1#", evaNumbers: ["ostkreuz": "8011162"]))
        #expect(share.train == "S5")
        #expect(share.product == .suburban)
        #expect(share.color != nil)
        #expect(share.color == journey.legs[1].line?.lineColorHex)
        #expect(share.journeyId == "2|#VN#1#")
        #expect(share.stops.map(\.name) == ["Berlin Hbf", "Berlin Ostkreuz"])
        #expect(share.stops.map(\.eva) == ["8011160", "8011162"])
        // Where you board: the departure; where you get off: the arrival and its platform.
        #expect(share.stops[0].departure == start.addingTimeInterval(5 * 3600))
        #expect(share.stops[0].platform == "15")
        #expect(share.stops[1].arrivalLive == start.addingTimeInterval(5 * 3600 + 780))
        #expect(share.stops[1].platform == "3")
        #expect(share.stops[1].platformLive == "4")
    }

    @Test func onlyUntilTwoHoursAfterTheArrival() {
        let journey = journey()
        let arrival = start.addingTimeInterval(5 * 3600 + 780)
        #expect(ArrivalShare.canShare(journey, now: arrival.addingTimeInterval(2 * 3600 - 60)))
        #expect(!ArrivalShare.canShare(journey, now: arrival.addingTimeInterval(2 * 3600 + 60)))
        #expect(!ArrivalShare.canShare(Journey(legs: [journey.legs[2]], source: .transitous)))
    }

    @Test func usesTheLegsStopsWhenLoaded() throws {
        var journey = JourneyShareLinkTests.journey()
        let leg = journey.legs[0]
        journey.legs[0].stopovers = [
            Stopover(station: leg.origin, arrival: nil, departure: leg.departure, arrivalPlatform: nil,
                     departurePlatform: PlatformInfo(planned: "13", actual: nil), cancelled: false),
            Stopover(station: station("8000152", "Hannover Hbf"), arrival: leg.departure, departure: leg.departure,
                     arrivalPlatform: nil, departurePlatform: nil, cancelled: true),
            Stopover(station: leg.destination, arrival: leg.arrival, departure: nil,
                     arrivalPlatform: PlatformInfo(planned: "17", actual: nil), departurePlatform: nil, cancelled: false),
        ]
        let share = try #require(ArrivalShare(journey: journey))
        #expect(share.stops.map(\.name) == ["Hamburg Hbf", "Hannover Hbf", "Dresden Hbf"])
        #expect(share.stops.map(\.cancelled) == [false, true, false])
        #expect(share.stops[2].platform == "17")
        #expect(share.journeyId == nil)
    }
}
