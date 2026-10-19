import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct JourneyCalendarEventTests {
    let koeln = station("8000207", "Köln Hbf", 50.943, 6.959)
    let mannheim = station("8000244", "Mannheim Hbf")
    let muenchen = station("8000261", "München Hbf", 48.140, 11.558)
    let koelnDeutz = station("8003368", "Köln Messe/Deutz", 50.941, 6.975)
    let bonn = station("8000044", "Bonn Hbf", 50.732, 7.097)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let link = LiveActivityLink.url(journeyID: "ABC")

    func time(_ minutes: Double, delay: Double? = nil) -> TimeInfo {
        let planned = now.addingTimeInterval(minutes * 60)
        return TimeInfo(planned: planned, actual: delay.map { planned.addingTimeInterval($0 * 60) })
    }

    func leg(_ name: String, _ from: Station, _ to: Station, dep: TimeInfo, arr: TimeInfo, platform: PlatformInfo?) -> Leg {
        Leg(origin: from, destination: to, departure: dep, arrival: arr,
            departurePlatform: platform, arrivalPlatform: nil,
            tripId: "trip-\(name)", line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    @Test func directTrainIsNamedInTheTitle() throws {
        let journey = Journey(legs: [leg("ICE 597", koeln, muenchen, dep: time(0), arr: time(270),
                                         platform: PlatformInfo(planned: "5", actual: nil))], source: .bahnDe)
        let event = try #require(JourneyCalendarEvent(journey: journey, link: link))
        #expect(event.title == "ICE 597 → München")
        #expect(event.start == now)
        #expect(event.end == now.addingTimeInterval(270 * 60))
        #expect(event.location == "Köln Hbf")
        #expect(event.coordinate == koeln.coordinate)
        #expect(event.url == link)
        #expect(event.notes == "ICE 597 ab Gl. 5\n\nIn BetterBahn öffnen: betterbahn://journey?id=ABC")
    }

    /// Delays, the changed platform and the reserved seats come from the latest data.
    @Test func changesListTrainPlatformTransferTimeAndSeat() throws {
        let journey = Journey(legs: [
            leg("ICE 597", koeln, mannheim, dep: time(0, delay: 5), arr: time(120, delay: 5),
                platform: PlatformInfo(planned: "5", actual: "6")),
            leg("ICE 123", mannheim, muenchen, dep: time(140), arr: time(300), platform: PlatformInfo(planned: "3", actual: nil)),
        ], source: .bahnDe)
        let seat = SeatReservation(trainName: "ICE 123", coach: "7", seats: ["41", "42"])
        let event = try #require(JourneyCalendarEvent(journey: journey, reservations: [seat]))
        #expect(event.title == "Köln → München")
        #expect(event.start == now.addingTimeInterval(5 * 60))
        #expect(event.notes == """
            ICE 597 ab Gl. 6
            Umstieg in Mannheim Hbf (15 Min.): ICE 123 ab Gl. 3 · Wagen 7 · Plätze 41, 42
            """)
    }

    @Test func journeyWithoutTrainsHasNoEvent() {
        #expect(JourneyCalendarEvent(journey: Journey(legs: [], source: .bahnDe)) == nil)
    }

    /// Main stations lose "Hbf" only on long journeys; other stations keep their names.
    @Test func shortTitleOnlyForMainStationsOnLongJourneys() throws {
        let short = Journey(legs: [leg("RE 5", koeln, bonn, dep: time(0), arr: time(20), platform: nil)], source: .bahnDe)
        #expect(try #require(JourneyCalendarEvent(journey: short)).title == "RE 5 → Bonn Hbf")
        let long = Journey(legs: [leg("ICE 527", koelnDeutz, muenchen, dep: time(0), arr: time(270), platform: nil)], source: .bahnDe)
        let event = try #require(JourneyCalendarEvent(journey: long))
        #expect(event.title == "ICE 527 → München")
        #expect(event.location == "Köln Messe/Deutz")
    }

    /// "Bei Abfahrt" waits for the (realtime) departure, "Beim Speichern" doesn't; finished journeys get none.
    @Test func autoAddIsDueAtDepartureOrRightAway() {
        let journey = Journey(legs: [leg("ICE 597", koeln, muenchen, dep: time(30, delay: 10), arr: time(300),
                                         platform: nil)], source: .bahnDe)
        #expect(!CalendarAutoAdd.off.isDue(journey, now: now))
        #expect(CalendarAutoAdd.onSave.isDue(journey, now: now))
        #expect(!CalendarAutoAdd.onDeparture.isDue(journey, now: now.addingTimeInterval(35 * 60)))
        #expect(CalendarAutoAdd.onDeparture.isDue(journey, now: now.addingTimeInterval(40 * 60)))
        #expect(!CalendarAutoAdd.onSave.isDue(journey, now: now.addingTimeInterval(400 * 60)))
    }
}
