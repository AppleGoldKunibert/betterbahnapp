import Foundation
import Testing
@testable import BetterBahnKit

/// Check-in reminders (#519): 5 minutes after a train departs, unless checked in.
@Suite struct CheckinReminderTests {
    let frankfurt = station("8000105", "Frankfurt (Main) Hbf")
    let fulda = station("8000115", "Fulda")
    let berlin = station("8011160", "Berlin Hbf")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func time(_ minutes: Double, delay: Double? = nil) -> TimeInfo {
        let planned = now.addingTimeInterval(minutes * 60)
        return TimeInfo(planned: planned, actual: delay.map { planned.addingTimeInterval($0 * 60) })
    }

    func leg(_ name: String, _ from: Station, _ to: Station, dep: TimeInfo, arr: TimeInfo, cancelled: Bool = false) -> Leg {
        Leg(origin: from, destination: to, departure: dep, arrival: arr,
            departurePlatform: nil, arrivalPlatform: nil,
            tripId: "trip-\(name)", line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: cancelled, stopovers: [], remarks: [], source: .bahnDe)
    }

    var journey: Journey {
        Journey(legs: [
            leg("ICE 1000", frankfurt, fulda, dep: time(10, delay: 3), arr: time(40)),
            leg("ICE 578", fulda, berlin, dep: time(60), arr: time(240)),
        ], source: .bahnDe)
    }

    @Test func comesFiveMinutesAfterTheLiveDeparture() throws {
        let reminders = journey.checkinReminders(now: now)
        #expect(reminders.count == 2)
        let first = try #require(reminders.first)
        #expect(first.fireDate == now.addingTimeInterval((10 + 3 + 5) * 60))
        #expect(first.title == "Schon eingecheckt?")
        #expect(first.body == "Check dich jetzt in ICE 1000 nach Fulda ein.")
    }

    @Test func checkedInOrCancelledOrPastTrainsGetNone() {
        let journey = journey
        #expect(journey.checkinReminders(now: now, checkedIn: [journey.legs[0].id]).map(\.legID) == [journey.legs[1].id])
        // 20 min in: the first reminder (at 18 min) has passed.
        #expect(journey.checkinReminders(now: now.addingTimeInterval(20 * 60)).map(\.legID) == [journey.legs[1].id])
        let cancelled = Journey(legs: [leg("ICE 1", frankfurt, fulda, dep: time(10), arr: time(40), cancelled: true)], source: .bahnDe)
        #expect(cancelled.checkinReminders(now: now).isEmpty)
    }

    @Test func notificationPointsAtTheJourneyAndLeg() throws {
        let entry = UUID()
        // bahn.de's trip IDs contain "|" themselves.
        let legID = "2|#VN#1#ST#1763|8000105" + "2026-11-17 10:00:00 +0000"
        let identifier = CheckinReminder.notificationID(entry: entry, legID: legID)
        let target = try #require(CheckinReminder.target(ofNotificationID: identifier))
        #expect(target.entry == entry)
        #expect(target.legID == legID)
        #expect(CheckinReminder.target(ofNotificationID: "exit|" + entry.uuidString + "|x") == nil)
        #expect(CheckinReminder.target(ofNotificationID: "checkin|nojourney|x") == nil)
        #expect(CheckinReminder.target(ofNotificationID: "checkin|" + entry.uuidString + "|") == nil)
    }

    @Test func outcomeOfTheReminderButtonSaysWhatToDo() {
        let leg = journey.legs[0]
        #expect(ReminderCheckinOutcome.checkedIn.title == "Eingecheckt")
        #expect(ReminderCheckinOutcome.checkedIn.body(for: leg) == "Du bist in ICE 1000 nach Fulda eingecheckt.")
        #expect(ReminderCheckinOutcome.trainNotFound.title == "Noch nicht eingecheckt")
        #expect(ReminderCheckinOutcome.trainNotFound.body(for: leg) == "Träwelling kennt ICE 1000 nicht. Tippe hier, um ihn selbst einzutragen.")
    }
}
