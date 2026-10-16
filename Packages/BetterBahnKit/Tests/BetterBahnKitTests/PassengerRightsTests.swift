import Foundation
import Testing
@testable import BetterBahnKit

/// Fahrgastrechte (#311): 25 % from 60 minutes late at the destination, 50 % from 120.
struct PassengerRightsTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func leg(_ name: String, product: Product, to: String = "berlin", delay: TimeInterval, cancelled: Bool = false,
             arrivesIn arrives: TimeInterval = -4 * 3600) -> Leg {
        let departure = now.addingTimeInterval(arrives - 3600), arrival = now.addingTimeInterval(arrives)
        return Leg(origin: station("hamburg", "hamburg", source: .transitous), destination: station(to, to, source: .transitous),
                   departure: TimeInfo(planned: departure, actual: departure),
                   arrival: TimeInfo(planned: arrival, actual: arrival.addingTimeInterval(delay * 60)),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: name,
                   line: Line(name: name, number: nil, product: product, operatorName: nil), direction: nil,
                   isWalking: false, cancelled: cancelled, stopovers: [], remarks: [], source: .transitous)
    }

    func journey(_ product: Product = .highSpeed, delay: TimeInterval) -> Journey {
        Journey(legs: [leg("ICE 1", product: product, delay: delay)], source: .transitous)
    }

    @Test func thresholds() {
        #expect(PassengerRights.compensation(forDelay: 59) == nil)
        #expect(PassengerRights.compensation(forDelay: 60) == .quarter)
        #expect(PassengerRights.compensation(forDelay: 119) == .quarter)
        #expect(PassengerRights.compensation(forDelay: 120) == .half)
    }

    @Test func delayedLongDistanceTrainHasAClaim() {
        let claim = PassengerRights.claim(for: journey(delay: 75), hasTicket: false, hasBahnCard100: false, now: now)
        #expect(claim?.compensation == .quarter)
        #expect(claim?.delayMinutes == 75)
        #expect(claim?.cause == .delay)
        #expect(PassengerRights.claim(for: journey(delay: 130), hasTicket: false, hasBahnCard100: false, now: now)?.compensation == .half)
        #expect(PassengerRights.claim(for: journey(delay: 59), hasTicket: false, hasBahnCard100: false, now: now) == nil)
    }

    @Test func regionalTrainsOnlyCountWithTicketOrBahnCard100() {
        let late = journey(.regional, delay: 90)
        #expect(PassengerRights.claim(for: late, hasTicket: false, hasBahnCard100: false, now: now) == nil)
        #expect(PassengerRights.claim(for: late, hasTicket: true, hasBahnCard100: false, now: now) != nil)
        let flat = PassengerRights.claim(for: late, hasTicket: false, hasBahnCard100: true, now: now)
        #expect(flat?.isFlatRate == true)
    }

    @Test func notArrivedYetOrWithoutLiveDataThereIsNoClaim() {
        let later = Journey(legs: [leg("ICE 1", product: .highSpeed, delay: 90, arrivesIn: 600)], source: .transitous)
        #expect(PassengerRights.claim(for: later, hasTicket: true, hasBahnCard100: false, now: now) == nil)
        var unknown = journey(delay: 90)
        unknown.legs[0].arrival.actual = nil
        #expect(PassengerRights.claim(for: unknown, hasTicket: true, hasBahnCard100: false, now: now) == nil)
    }

    @Test func cancelledLastLegHasNoClaim() {
        let cancelled = Journey(legs: [leg("ICE 1", product: .highSpeed, delay: 90, cancelled: true)], source: .transitous)
        #expect(PassengerRights.claim(for: cancelled, hasTicket: true, hasBahnCard100: false, now: now) == nil)
    }

    @Test func replacedPlanIsMeasuredAgainstTheBookedOne() {
        let booked = journey(delay: 0)
        // The replacement arrives on time by its own plan, but 65 minutes after the booked one.
        var replacement = Journey(legs: [leg("ICE 2", product: .highSpeed, delay: 0, arrivesIn: -4 * 3600 + 65 * 60)], source: .transitous)
        replacement.legs[0].arrival.actual = replacement.legs[0].arrival.planned
        let claim = PassengerRights.claim(for: replacement, earlierPlans: [booked], hasTicket: true, hasBahnCard100: false,
                                          now: now)
        #expect(claim?.cause == .replanned)
        #expect(claim?.compensation == .quarter)
        #expect(claim?.delayMinutes == 65)
    }

    @Test func earlierPlanToAnotherDestinationIsIgnored() {
        let elsewhere = Journey(legs: [leg("ICE 3", product: .highSpeed, to: "muenchen", delay: 0, arrivesIn: -7200)], source: .transitous)
        let claim = PassengerRights.claim(for: journey(delay: 10), earlierPlans: [elsewhere], hasTicket: true, hasBahnCard100: false, now: now)
        #expect(claim == nil)
    }

    @Test func requestTextHasWhatTheFormAsks() throws {
        let late = journey(delay: 75)
        let claim = try #require(PassengerRights.claim(for: late, hasTicket: true, hasBahnCard100: false, now: now))
        let text = PassengerRights.requestText(for: late, claim: claim, orderNumbers: ["ABC123"])
        #expect(text.contains("Von: \(late.legs[0].origin.displayName)"))
        #expect(text.contains("Nach: \(late.legs[0].destination.displayName)"))
        #expect(text.contains("ICE 1"))
        #expect(text.contains("Geplante Abfahrt: "))
        #expect(text.contains("Verspätung am Ziel: 75 Minuten"))
        #expect(text.contains("Auftragsnummer: ABC123"))
    }

    @Test func missedConnectionIsMarked() {
        // ICE 1 arrives 70 minutes late in Köln, after ICE 2 left.
        let booked = Journey(legs: [
            leg("ICE 1", product: .highSpeed, to: "koeln", delay: 70, arrivesIn: -5 * 3600),
            leg("ICE 2", product: .highSpeed, delay: 0, arrivesIn: -4 * 3600),
        ], source: .transitous)
        #expect(!booked.brokenTransferIndices.isEmpty)
        var replacement = Journey(legs: [leg("ICE 3", product: .highSpeed, delay: 0, arrivesIn: -4 * 3600 + 65 * 60)], source: .transitous)
        replacement.legs[0].arrival.actual = replacement.legs[0].arrival.planned
        let claim = PassengerRights.claim(for: replacement, earlierPlans: [booked], hasTicket: true, hasBahnCard100: false, now: now)
        #expect(claim?.cause == .missedConnection)
        #expect(claim?.delayMinutes == 65)
    }
}
