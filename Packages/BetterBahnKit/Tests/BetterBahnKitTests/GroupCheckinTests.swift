import Foundation
import Testing
@testable import BetterBahnKit

/// Checking in on every train of a journey at once (#574).
@Suite struct GroupCheckinTests {
    let frankfurt = station("8000105", "Frankfurt (Main) Hbf")
    let fulda = station("8000115", "Fulda")
    let kassel = station("8000193", "Kassel-Wilhelmshöhe")
    let berlin = station("8011160", "Berlin Hbf")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func leg(_ name: String, _ from: Station, _ to: Station, at minutes: Double, cancelled: Bool = false, walking: Bool = false) -> Leg {
        Leg(origin: from, destination: to,
            departure: TimeInfo(planned: now.addingTimeInterval(minutes * 60), actual: nil),
            arrival: TimeInfo(planned: now.addingTimeInterval((minutes + 30) * 60), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil,
            tripId: walking ? nil : "trip-\(name)",
            line: walking ? nil : Line(name: name, number: nil, product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: walking, cancelled: cancelled, stopovers: [], remarks: [], source: .bahnDe)
    }

    @Test func coversEveryTrainThatRuns() {
        let journey = Journey(legs: [
            leg("ICE 1", frankfurt, fulda, at: 0),
            leg("Fußweg", fulda, fulda, at: 30, walking: true),
            leg("ICE 2", fulda, kassel, at: 40, cancelled: true),
            leg("ICE 3", fulda, kassel, at: 50),
        ], source: .bahnDe)
        #expect(journey.groupCheckinLegs.map(\.line?.name) == ["ICE 1", "ICE 3"])
        #expect(journey.offersGroupCheckin)
        let single = Journey(legs: [leg("ICE 1", frankfurt, fulda, at: 0)], source: .bahnDe)
        #expect(!single.offersGroupCheckin)
    }

    @Test func sendsWhatIsLeftInOrder() {
        let legs = [leg("ICE 1", frankfurt, fulda, at: 0), leg("ICE 2", fulda, kassel, at: 40), leg("ICE 3", kassel, berlin, at: 80)]
        var group = GroupCheckin(legs: legs, checkedIn: [legs[0].id])
        #expect(!group.hasStarted)
        #expect(group.toSend == [legs[1].id, legs[2].id])

        group.set(.sending, for: legs[1].id)
        #expect(group.isSending)
        #expect(group.hasStarted)
        group.set(.checkedIn(points: 12, companions: 0), for: legs[1].id)
        group.set(.trainNotFound, for: legs[2].id)
        #expect(!group.isDone)
        // The unknown train waits for the user: entering it by hand is their choice.
        #expect(group.toSend.isEmpty)

        group.set(.failed("offline"), for: legs[2].id)
        #expect(group.toSend == [legs[2].id])
        group.set(.checkedIn(points: 3, companions: 1), for: legs[2].id)
        #expect(group.isDone)
        #expect(group.points == 15)
        #expect(group.checkedInCount == 2)
    }

    @Test func coupledTrainsAskWhichPart() {
        var coupled = leg("ICE 940", frankfurt, fulda, at: 0)
        coupled.line?.coupledTrains = [Line.CoupledTrain(name: "ICE 950", direction: "Berlin Hbf")]
        #expect(coupled.needsCoupledTrainChoice)
        #expect(!leg("ICE 1", frankfurt, fulda, at: 0).needsCoupledTrainChoice)
        #expect(coupled.riding(trainNamed: nil).line?.name == "ICE 940")
        #expect(coupled.riding(trainNamed: "ICE 940").line?.name == "ICE 940")
        #expect(coupled.riding(trainNamed: "ICE 950").line?.name == "ICE 950")
        #expect(coupled.riding(trainNamed: "ICE 950").direction == "Berlin Hbf")
    }
}
