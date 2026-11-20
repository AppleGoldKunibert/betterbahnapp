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

    /// A footpath after `train` to `to`, as Transitous returns them: walks never get live times.
    func walk(after train: Leg, to: String = "dom", minutes: TimeInterval = 10) -> Leg {
        let start = train.arrival.planned
        return Leg(origin: train.destination, destination: station(to, to, source: .transitous),
                   departure: TimeInfo(planned: start, actual: nil),
                   arrival: TimeInfo(planned: start.addingTimeInterval(minutes * 60), actual: nil),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: nil, line: nil, direction: nil,
                   isWalking: true, cancelled: false, stopovers: [], remarks: [], source: .transitous)
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

    @Test func walkAtTheEndDoesNotHideTheDelay() throws {
        // #565: the ICE arrives 90 minutes late, then a walk without live times ends the journey.
        let train = leg("ICE 1", product: .highSpeed, delay: 90)
        let late = Journey(legs: [train, walk(after: train)], source: .transitous)
        let claim = try #require(PassengerRights.claim(for: late, hasTicket: false, hasBahnCard100: false, now: now))
        #expect(claim.compensation == .quarter)
        #expect(claim.delayMinutes == 90)
        #expect(claim.plannedArrival == train.arrival.planned)
        // The form names the stations of the trains, not where the walk ends.
        let fields = PassengerRights.requestFields(for: late, claim: claim, orderNumbers: [])
        #expect(fields.first { $0.label == "Nach" }?.value == train.destination.displayName)

        // A replacement ending with the same walk is measured from train to train as well.
        let bookedTrain = leg("ICE 1", product: .highSpeed, delay: 0)
        let booked = Journey(legs: [bookedTrain, walk(after: bookedTrain)], source: .transitous)
        var replacementTrain = leg("ICE 2", product: .highSpeed, delay: 0, arrivesIn: -4 * 3600 + 65 * 60)
        replacementTrain.arrival.actual = nil
        let replacement = Journey(legs: [replacementTrain, walk(after: replacementTrain)], source: .transitous)
        let replanned = PassengerRights.claim(for: replacement, earlierPlans: [booked], hasTicket: true,
                                              hasBahnCard100: false, now: now)
        #expect(replanned?.delayMinutes == 65)

        // A cancelled last train still means no claim, whatever walk follows.
        var cancelled = train
        cancelled.cancelled = true
        let gone = Journey(legs: [cancelled, walk(after: cancelled)], source: .transitous)
        #expect(PassengerRights.claim(for: gone, hasTicket: true, hasBahnCard100: false, now: now) == nil)
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

    @Test func requestOfAReplannedJourneyNamesTheBookedConnection() throws {
        let booked = journey(delay: 0)
        // ICE 1 was cancelled; ICE 2 leaves 42 minutes later and arrives 75 minutes after the booked plan.
        var replacement = Journey(legs: [leg("ICE 2", product: .highSpeed, delay: 0, arrivesIn: -4 * 3600 + 75 * 60)], source: .transitous)
        replacement.legs[0].departure = TimeInfo(planned: booked.legs[0].departure.planned.addingTimeInterval(42 * 60), actual: nil)
        replacement.legs[0].arrival.actual = replacement.legs[0].arrival.planned
        let claim = try #require(PassengerRights.claim(for: replacement, earlierPlans: [booked], hasTicket: true,
                                                       hasBahnCard100: false, now: now))
        let fields = PassengerRights.requestFields(for: replacement, earlierPlans: [booked], claim: claim, orderNumbers: [])
        func value(_ label: String) -> String? { fields.first { $0.label == label }?.value }

        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let german = Locale(identifier: "de_DE")
        let bookedDeparture = booked.legs[0].departure.planned
        #expect(value("Geplante Abfahrt") == bookedDeparture.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: german, timeZone: berlin)))
        #expect(value("Reisedatum") == bookedDeparture.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: german, timeZone: berlin)))
        #expect(value("Geplante Ankunft") == booked.legs[0].arrival.planned.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: german, timeZone: berlin)))
        #expect(value("Züge") == nil)
        #expect(value("Gebuchte Züge")?.hasPrefix("ICE 1: ") == true)
        #expect(value("Gefahrene Züge")?.hasPrefix("ICE 2: ") == true)
        #expect(value("Verspätung am Ziel") == "75 Minuten")

        // Without the earlier plans only the journey itself is known: one list of trains.
        let plain = PassengerRights.requestFields(for: booked, claim: claim, orderNumbers: [])
        #expect(plain.contains { $0.label == "Züge" })
        #expect(!plain.contains { $0.label == "Gefahrene Züge" })
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
