import Foundation
import Testing
@testable import BetterBahnKit

/// Journeys that are over: a transfer that worked thanks to a delay mustn't turn into "missed" once
/// the trains' live data is gone.
struct PastJourneyTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func leg(_ name: String, from: String, to: String, departs: TimeInterval, arrives: TimeInterval,
             delay: TimeInterval = 0, tripId: String? = nil) -> Leg {
        let departure = now.addingTimeInterval(departs), arrival = now.addingTimeInterval(arrives)
        return Leg(origin: station(from, from, source: .transitous), destination: station(to, to, source: .transitous),
                   departure: TimeInfo(planned: departure, actual: departure.addingTimeInterval(delay)),
                   arrival: TimeInfo(planned: arrival, actual: arrival.addingTimeInterval(delay)),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: tripId ?? name,
                   line: Line(name: name, number: nil, product: .regional, operatorName: nil), direction: nil,
                   isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    /// RE 50 arrives in Hanau at 13:44, the ICE planned for 13:30 left 20 minutes late, as the
    /// replanned journey expected; a few hours later only the RE's live data is left.
    func journey(endsIn hours: Double) -> Journey {
        let end = hours * 3600
        return Journey(legs: [
            leg("RE 50", from: "frankfurt", to: "hanau", departs: end - 4 * 3600, arrives: end - 3.5 * 3600),
            leg("ICE 372", from: "hanau", to: "berlin", departs: end - 3.7 * 3600, arrives: end),
        ], source: .transitous)
    }

    @Test func pastJourneyShowsNoTransferWarnings() {
        let past = journey(endsIn: -1)
        #expect(past.isOver(now: now))
        #expect(past.connectionIssues().contains { $0.isBlocking })
        #expect(past.currentIssues(now: now).isEmpty)

        let upcoming = journey(endsIn: 2)
        #expect(!upcoming.isOver(now: now))
        #expect(upcoming.currentIssues(now: now).contains { $0.isBlocking })
    }

    @Test func pastJourneyStillShowsCancellations() {
        var past = journey(endsIn: -1)
        past.legs[1].cancelled = true
        let issues = past.currentIssues(now: now)
        #expect(issues.count == 1)
        #expect(issues.first?.title == "ICE 372 fällt aus")
    }

    @Test func legsLongOverAreNotRefreshedAnyMore() {
        let done = leg("RE 50", from: "frankfurt", to: "hanau", departs: -3 * 3600, arrives: -2 * 3600)
        let running = leg("ICE 372", from: "hanau", to: "berlin", departs: -1800, arrives: 3600)
        let justArrived = leg("S 8", from: "a", to: "b", departs: -1800, arrives: -600)
        #expect(JourneyRefresher.isLongOver(done, now: now))
        #expect(!JourneyRefresher.isLongOver(running, now: now))
        #expect(!JourneyRefresher.isLongOver(justArrived, now: now))
    }

    @Test func savedZusatzhaltStaysInTheTrainsRun() {
        func stop(_ id: String, _ minutes: TimeInterval, additional: Bool = false) -> Stopover {
            let time = TimeInfo(planned: now.addingTimeInterval(minutes * 60), actual: nil)
            return Stopover(station: station(id, id, source: .transitous), arrival: time, departure: time,
                            arrivalPlatform: nil, departurePlatform: nil, cancelled: false, isAdditional: additional)
        }
        var ridden = leg("ICE 372", from: "hanau", to: "zusatz", departs: 0, arrives: 50 * 60)
        ridden.stopovers = [stop("hanau", 0), stop("fulda", 30), stop("zusatz", 50, additional: true)]
        let run = Trip(id: "372", line: ridden.line, direction: "Berlin",
                       stopovers: [stop("frankfurt", -20), stop("hanau", 0), stop("fulda", 30), stop("kassel", 70)],
                       cancelled: false, remarks: [], source: .transitous)

        let kept = run.keepingAdditionalStops(of: ridden)
        #expect(kept.stopovers.map(\.station.id) == ["frankfurt", "hanau", "fulda", "zusatz", "kassel"])
        #expect(kept.keepingAdditionalStops(of: ridden).stopovers.count == 5)
    }
}
