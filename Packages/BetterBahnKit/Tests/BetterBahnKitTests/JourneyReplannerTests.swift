import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct JourneyReplanTests {
    private func time(_ minutes: Int) -> Date { Date(timeIntervalSince1970: 0).addingTimeInterval(TimeInterval(minutes * 60)) }

    private func leg(_ line: String?, from: String, to: String, depart: Int, arrive: Int,
                     tripId: String? = nil) -> Leg {
        Leg(origin: station(from, from), destination: station(to, to),
            departure: TimeInfo(planned: time(depart), actual: nil),
            arrival: TimeInfo(planned: time(arrive), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: tripId ?? line.map { "trip-\($0)" },
            line: line.map { Line(name: $0, number: nil, product: .regionalExpress, operatorName: nil) },
            direction: nil, isWalking: line == nil, cancelled: false,
            stopovers: [], remarks: [], source: .bahnDe)
    }

    @Test func rebuildKeepsEarlierLegsAndAppendsContinuation() {
        let first = leg("RE 1", from: "A", to: "B", depart: 0, arrive: 30)
        let second = leg("RE 2", from: "B", to: "C", depart: 40, arrive: 90)
        let journey = Journey(legs: [first, second], source: .bahnDe)
        // Get off the second train in X instead of C, then carry on from there.
        let shortened = leg("RE 2", from: "B", to: "X", depart: 40, arrive: 60)
        let continuation = Journey(legs: [leg("RB 9", from: "X", to: "C", depart: 70, arrive: 100)], source: .bahnDe)

        let rebuilt = JourneyReplanner.rebuild(journey, replacingLegAt: 1, with: shortened, continuation: continuation)

        #expect(rebuilt.legs.count == 3)
        #expect(rebuilt.legs[0] == first)
        #expect(rebuilt.legs[1].destination.name == "X")
        #expect(rebuilt.legs[2].line?.name == "RB 9")
        #expect(rebuilt.arrival?.planned == time(100))
    }

    @Test func rebuildWithoutContinuationEndsAtTheNewExit() {
        let journey = Journey(legs: [leg("RE 1", from: "A", to: "C", depart: 0, arrive: 60)], source: .bahnDe)
        let shortened = leg("RE 1", from: "A", to: "B", depart: 0, arrive: 40)

        let rebuilt = JourneyReplanner.rebuild(journey, replacingLegAt: 0, with: shortened, continuation: nil)

        #expect(rebuilt.legs.count == 1)
        #expect(rebuilt.legs[0].destination.name == "B")
        #expect(rebuilt.arrival?.planned == time(40))
    }

    /// Staying on the same train must not show that train twice.
    @Test func rebuildMergesAContinuationOnTheSameTrip() {
        let ride = leg("ICE 5", from: "A", to: "C", depart: 0, arrive: 120, tripId: "ice5")
        let journey = Journey(legs: [ride], source: .bahnDe)
        let shortened = leg("ICE 5", from: "A", to: "B", depart: 0, arrive: 60, tripId: "ice5")
        let sameTrain = Journey(legs: [leg("ICE 5", from: "B", to: "D", depart: 60, arrive: 150, tripId: "ice5")],
                                source: .bahnDe)

        let rebuilt = JourneyReplanner.rebuild(journey, replacingLegAt: 0, with: shortened, continuation: sameTrain)

        #expect(rebuilt.legs.count == 1)
        #expect(rebuilt.legs[0].origin.name == "A")
        #expect(rebuilt.legs[0].destination.name == "D")
        #expect(rebuilt.arrival?.planned == time(150))
    }

    @Test func legEndingAtAnEarlierStopIsBuiltFromTheTripsStops() throws {
        let stops = ["A", "B", "C"].enumerated().map { index, name in
            Stopover(station: station(name, name),
                     arrival: TimeInfo(planned: time(index * 30), actual: nil),
                     departure: TimeInfo(planned: time(index * 30 + 2), actual: nil),
                     arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let trip = Trip(id: "t1", line: Line(name: "RE 1", number: "1", product: .regionalExpress, operatorName: nil),
                        direction: "C", stopovers: stops, cancelled: false, remarks: [], source: .bahnDe)

        let shortened = try #require(trip.leg(from: station("A", "A"), to: station("B", "B")))

        #expect(shortened.destination.name == "B")
        #expect(shortened.arrival.planned == time(30))
        #expect(shortened.stopovers.count == 2)
    }
}

/// Getting off somewhere else than planned: which stops may be proposed, and which one wins.
@Suite struct ExitOptionTests {
    let a = station("1", "Stop A", 52.0, 13.0)
    let b = station("2", "Stop B", 52.3, 13.0)
    let c = station("3", "Stop C", 52.5, 13.0)
    let d = station("4", "Stop D", 53.0, 13.0)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func time(_ minutes: Double) -> TimeInfo { TimeInfo(planned: base.addingTimeInterval(minutes * 60), actual: nil) }

    private func stop(_ s: Station, arr: Double?, dep: Double?) -> Stopover {
        Stopover(station: s, arrival: arr.map(time), departure: dep.map(time),
                 arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    /// A → C → D, boarding in A.
    private func ride() -> Trip {
        Trip(id: "ice1", line: Line(name: "ICE 1", number: "1", product: .highSpeed, operatorName: nil),
             direction: "Stop D",
             stopovers: [stop(a, arr: nil, dep: 0), stop(c, arr: 60, dep: 62), stop(d, arr: 120, dep: nil)],
             cancelled: false, remarks: [], source: .bahnDe)
    }

    private func journey(_ from: Station, _ to: Station, dep: Double, arr: Double) -> Journey {
        let trip = Trip(id: "rb-\(dep)", line: Line(name: "RB 10", number: "10", product: .regional, operatorName: nil),
                        direction: to.name, stopovers: [stop(from, arr: nil, dep: dep), stop(to, arr: arr, dep: nil)],
                        cancelled: false, remarks: [], source: .bahnDe)
        return Journey(legs: [trip.leg(from: from, to: to)!], source: .bahnDe)
    }

    /// New goal B: riding on to D and coming back is slower than leaving the train in C.
    @Test func prefersTheEarlierExitWhenTheGoalLiesBehindIt() async throws {
        let mock = RoutingMockProvider()
        mock.routes["Stop C -> Stop B"] = [journey(c, b, dep: 70, arr: 90)]
        mock.routes["Stop D -> Stop B"] = [journey(d, b, dep: 130, arr: 190)]
        let replanner = JourneyReplanner(provider: mock)

        let options = await replanner.exitOptions(on: ride(), boardingAt: a, notBefore: base,
                                                  options: ReplanOptions(destination: b, minTransferMinutes: 5))

        let best = try #require(options.first)
        #expect(best.exit.station.name == "Stop C")
        #expect(best.arrival == base.addingTimeInterval(90 * 60))
        #expect(best.ride.destination.name == "Stop C")
        // The boarding station itself is never offered – the train has already left it.
        #expect(!options.contains { $0.exit.station.name == "Stop A" })
        #expect(!mock.journeyQueries.contains { $0.hasPrefix("Stop A ->") })
    }

    /// Stops the train has already called at are no route to anywhere.
    @Test func skipsStopsThatArePassed() async throws {
        let mock = RoutingMockProvider()
        mock.routes["Stop C -> Stop B"] = [journey(c, b, dep: 70, arr: 90)]
        mock.routes["Stop D -> Stop B"] = [journey(d, b, dep: 130, arr: 190)]
        let replanner = JourneyReplanner(provider: mock)

        // Standing between C and D: C is behind us, only D is left.
        let options = await replanner.exitOptions(on: ride(), boardingAt: a,
                                                  notBefore: base.addingTimeInterval(90 * 60),
                                                  options: ReplanOptions(destination: b, minTransferMinutes: 5))

        #expect(options.map(\.exit.station.name) == ["Stop D"])
    }

    /// An exit that already is the goal needs no onward connection.
    @Test func exitAtTheGoalItselfNeedsNoContinuation() async throws {
        let mock = RoutingMockProvider()
        let replanner = JourneyReplanner(provider: mock)

        let options = await replanner.exitOptions(on: ride(), boardingAt: a, notBefore: base,
                                                  options: ReplanOptions(destination: c))

        let best = try #require(options.first)
        #expect(best.exit.station.name == "Stop C")
        #expect(best.continuation == nil)
        #expect(best.arrival == base.addingTimeInterval(60 * 60))
    }
}
