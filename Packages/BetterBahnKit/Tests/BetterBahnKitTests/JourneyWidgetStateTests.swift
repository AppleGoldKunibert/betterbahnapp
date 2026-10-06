import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct JourneyWidgetStateTests {
    private func time(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 0).addingTimeInterval(minutes * 60) }

    private func leg(_ line: Line?, from: String, to: String, depart: Double, arrive: Double,
                     departDelay: Double = 0, arriveDelay: Double = 0, platforms: (String, String)? = nil,
                     stops: [(String, Double)] = []) -> Leg {
        let departure = TimeInfo(planned: time(depart), actual: time(depart + departDelay))
        let arrival = TimeInfo(planned: time(arrive), actual: time(arrive + arriveDelay))
        var stopovers: [Stopover] = []
        if !stops.isEmpty {
            stopovers.append(Stopover(station: station(from, from), arrival: nil, departure: departure,
                                      arrivalPlatform: nil, departurePlatform: nil, cancelled: false))
            for (name, minute) in stops {
                let at = TimeInfo(planned: time(minute), actual: time(minute + arriveDelay))
                stopovers.append(Stopover(station: station(name, name), arrival: at, departure: at,
                                          arrivalPlatform: nil, departurePlatform: nil, cancelled: false))
            }
            stopovers.append(Stopover(station: station(to, to), arrival: arrival, departure: nil,
                                      arrivalPlatform: nil, departurePlatform: nil, cancelled: false))
        }
        return Leg(origin: station(from, from), destination: station(to, to), departure: departure, arrival: arrival,
                   departurePlatform: platforms.map { PlatformInfo(planned: $0.0, actual: nil) },
                   arrivalPlatform: platforms.map { PlatformInfo(planned: $0.1, actual: nil) },
                   tripId: line.map { "trip-\($0.name)" }, line: line, direction: to,
                   isWalking: line == nil, cancelled: false, stopovers: stopovers, remarks: [], source: .bahnDe)
    }

    private let re = Line(name: "RE 5", number: "5", product: .regionalExpress, operatorName: nil, tripNumber: "3307")
    private let ice = Line(name: "ICE 645", number: "645", product: .highSpeed, operatorName: nil)

    /// RE 5 Bonn → Köln 0–30 (+2 at Köln, via Brühl at 15), walk, ICE 645 Köln → Berlin 40–300 (+5 at Berlin).
    private var journey: Journey {
        Journey(legs: [
            leg(re, from: "Bonn Hbf", to: "Köln Hbf", depart: 0, arrive: 30, departDelay: 1, arriveDelay: 2,
                platforms: ("1", "4"), stops: [("Brühl", 15)]),
            leg(nil, from: "Köln Hbf", to: "Köln Hbf", depart: 32, arrive: 36),
            leg(ice, from: "Köln Hbf", to: "Berlin Hbf", depart: 40, arrive: 300, arriveDelay: 5, platforms: ("7", "12")),
        ], source: .bahnDe)
    }

    private func state(at minutes: Double) -> JourneyWidgetState { JourneyWidgetState.from(journey, now: time(minutes))! }

    @Test func showsTheFirstDepartureBeforeTheJourney() {
        let state = state(at: -20)
        #expect(state.phase == .beforeDeparture)
        #expect(state.trainName == "RE 5")
        #expect(state.nextStopName == "Bonn Hbf")
        #expect(state.platform == "1")
        #expect(state.nextStopDelayMinutes == 1)
        #expect(state.countdownEnd(.nextConnection) == time(1))
        #expect(state.countdownEnd(.destination) == time(305))
        #expect(state.finalDelayMinutes == 5)
        #expect(state.legIndex == 0)
    }

    @Test func showsTheNextStopWhileRiding() {
        let state = state(at: 5)
        #expect(state.phase == .riding)
        #expect(state.nextStopName == "Brühl")
        #expect(state.nextStopDelayMinutes == 2)
        #expect(state.transfer == nil)
        // The countdown goes to the next train.
        #expect(state.countdownEnd(.nextConnection) == time(40))
    }

    @Test func showsTheTransferShortlyBeforeArriving() {
        let state = state(at: 25)
        #expect(state.phase == .transfer)
        #expect(state.transfer?.fromTrain == "RE 5")
        #expect(state.transfer?.toTrain == "ICE 645")
        #expect(state.transfer?.fromPlatform == "4")
        #expect(state.transfer?.toPlatform == "7")
        #expect(state.transfer?.station == "Köln Hbf")
    }

    @Test func showsTheTransferWhileWaitingAndSkipsTheWalk() {
        let state = state(at: 34)
        #expect(state.phase == .transfer)
        #expect(state.trainName == "ICE 645")
        #expect(state.legIndex == 2)
        #expect(state.platform == "7")
        #expect(state.transfer?.fromTrain == "RE 5")
    }

    @Test func countsDownToTheArrivalOnTheLastTrain() {
        let state = state(at: 100)
        #expect(state.phase == .riding)
        #expect(state.trainName == "ICE 645")
        #expect(state.nextDeparture == nil)
        #expect(state.countdownEnd(.nextConnection) == time(305))
        #expect(!state.countsToDeparture(.nextConnection))
    }

    @Test func arrivesAtTheEnd() {
        #expect(state(at: 306).phase == .arrived)
    }

    @Test func changeDatesCoverStopsArrivalsAndTransferLead() {
        let dates = JourneyWidgetState.changeDates(of: journey, after: time(0))
        #expect(dates.contains(time(1)))     // departure (late)
        #expect(dates.contains(time(17)))    // Brühl (late)
        #expect(dates.contains(time(22)))    // transfer lead before Köln
        #expect(dates.contains(time(32)))    // arrival Köln
        #expect(dates.contains(time(40)))
        #expect(dates.allSatisfy { $0 > time(0) })
        #expect(dates == dates.sorted())
    }

    @Test func namesTrainsWithoutRunNumbers() {
        #expect(state(at: 5).trainName == "RE 5")
    }

    @Test func mapLinkRoundTrips() {
        let url = TrainMapLink.url(journeyID: "a|b c&d", legIndex: 2)
        #expect(TrainMapLink.target(from: url)?.journeyID == "a|b c&d")
        #expect(TrainMapLink.target(from: url)?.legIndex == 2)
        #expect(TrainMapLink.target(from: LiveActivityLink.url(journeyID: "x")) == nil)
        #expect(TrainMapLink.target(from: URL(string: "betterbahn://map?journey=x&leg=-1")!) == nil)
    }

    @Test func snapshotComparesContentOnly() {
        let a = WidgetSnapshot(journey: journey, updatedAt: time(0))
        let b = WidgetSnapshot(journey: journey, updatedAt: time(10))
        #expect(a.hasSameContent(as: b))
        #expect(!a.hasSameContent(as: WidgetSnapshot(journey: nil)))
        #expect(!a.hasSameContent(as: nil))
    }

    @Test func snapshotRoundTripsThroughAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = WidgetSnapshot(journey: journey, updatedAt: time(0))
        WidgetStore.save(snapshot, to: url)
        #expect(WidgetStore.load(from: url) == snapshot)
    }
}
