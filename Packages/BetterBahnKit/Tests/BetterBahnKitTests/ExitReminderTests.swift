import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct ExitReminderTests {
    let frankfurt = station("8000105", "Frankfurt (Main) Hbf")
    let fulda = station("8000115", "Fulda")
    let berlin = station("8011160", "Berlin Hbf")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let lead: TimeInterval = 5 * 60

    func time(_ minutes: Double, delay: Double? = nil) -> TimeInfo {
        let planned = now.addingTimeInterval(minutes * 60)
        return TimeInfo(planned: planned, actual: delay.map { planned.addingTimeInterval($0 * 60) })
    }

    func leg(_ name: String, _ from: Station, _ to: Station, dep: TimeInfo, arr: TimeInfo,
             depPlatform: PlatformInfo? = nil) -> Leg {
        Leg(origin: from, destination: to, departure: dep, arrival: arr,
            departurePlatform: depPlatform, arrivalPlatform: nil,
            tripId: "trip-\(name)", line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    /// ICE 1000 Frankfurt → Fulda (+23), change to ICE 578 Fulda → Berlin (+23, Gl. 4 instead of 5).
    func journey(firstDelay: Double? = 23, secondDelay: Double? = 23, platform: PlatformInfo? = PlatformInfo(planned: "5", actual: "4")) -> Journey {
        Journey(legs: [
            leg("ICE 1000", frankfurt, fulda, dep: time(0, delay: firstDelay), arr: time(30, delay: firstDelay)),
            leg("ICE 578", fulda, berlin, dep: time(56, delay: secondDelay), arr: time(240, delay: secondDelay), depPlatform: platform),
        ], source: .bahnDe)
    }

    @Test func transferReminderNamesDelaysTransferTimeAndPlatform() throws {
        let reminders = journey().exitReminders(lead: lead, now: now, dispositions: [journey().legs[1].id: .waiting])
        let first = try #require(reminders.first)
        #expect(reminders.count == 2)
        #expect(first.fireDate == now.addingTimeInterval((30 + 23 - 5) * 60))
        #expect(first.title == "Gleich aussteigen: Fulda")
        #expect(first.body == "In 5 Min. (+23) Ankunft in Fulda – Umstieg in ICE 578 (+23), in 26 Min. auf Gl. 4 statt Gl. 5 (Anschluss wartet)")
        #expect(reminders.last?.body == "In 5 Min. (+23) Ankunft am Ziel Berlin Hbf")
    }

    @Test func onTimeTrainsShowNoDelayAndUnchangedPlatformNoAlternative() throws {
        let reminder = try #require(journey(firstDelay: nil, secondDelay: 0, platform: PlatformInfo(planned: "4", actual: nil))
            .exitReminders(lead: lead, now: now).first)
        #expect(reminder.body == "In 5 Min. Ankunft in Fulda – Umstieg in ICE 578, in 26 Min. auf Gl. 4")
    }

    @Test func departingBeforeTheArrivalIsSaid() throws {
        let reminder = try #require(journey(firstDelay: 30, secondDelay: nil).exitReminders(lead: lead, now: now).first)
        #expect(reminder.body == "In 5 Min. (+30) Ankunft in Fulda – Umstieg in ICE 578, fährt vor der Ankunft ab")
    }

    /// Only one reminder per stop: once its time passed, a new delay doesn't bring it back.
    @Test func shownReminderDoesNotComeAgain() {
        let later = now.addingTimeInterval(50 * 60)
        let shown = ["exit|" + journey().legs[0].id: now.addingTimeInterval(48 * 60)]
        let reminders = journey(firstDelay: 30).exitReminders(lead: lead, now: later, scheduled: shown)
        #expect(reminders.map(\.station) == ["Berlin Hbf"])
    }

    /// A reminder not shown yet moves with the arrival, also earlier.
    @Test func pendingReminderFollowsTheArrival() throws {
        let scheduled = ["exit|" + journey().legs[0].id: now.addingTimeInterval(48 * 60)]
        let reminder = try #require(journey(firstDelay: 10).exitReminders(lead: lead, now: now, scheduled: scheduled).first)
        #expect(reminder.fireDate == now.addingTimeInterval(35 * 60))
    }

    /// Within the lead time it comes right away, with the minutes that are left.
    @Test func lateReminderComesNowWithRemainingMinutes() throws {
        let soon = now.addingTimeInterval((30 + 23 - 2) * 60)
        let reminder = try #require(journey().exitReminders(lead: lead, now: soon).first)
        #expect(reminder.fireDate == soon)
        #expect(reminder.body.hasPrefix("In 2 Min. (+23) Ankunft in Fulda"))
        #expect(reminder.body(at: reminder.arrival).hasPrefix("Gleich (+23)"))
    }

    @Test func pastAndCancelledArrivalsHaveNoReminder() {
        var cancelled = journey()
        cancelled.legs[1].cancelled = true
        #expect(cancelled.exitReminders(lead: lead, now: now).map(\.station) == ["Fulda"])
        #expect(journey().exitReminders(lead: lead, now: now.addingTimeInterval(60 * 60)).map(\.station) == ["Berlin Hbf"])
    }
}
