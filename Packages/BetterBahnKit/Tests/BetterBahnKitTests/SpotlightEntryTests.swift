import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct SpotlightEntryTests {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    /// Wednesday, 21 October 2026, 10:00 in Berlin.
    private let now = ISO8601DateFormatter().date(from: "2026-10-21T08:00:00Z")!

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private let koeln = Station(id: "8000207", name: "Köln Hbf", coordinate: Coordinate(latitude: 50.943, longitude: 6.959),
                                evaNumber: "8000207", source: .bahnDe, region: "Nordrhein-Westfalen")
    private let frankfurt = Station(id: "8000105", name: "Frankfurt(Main)Hbf", coordinate: nil, evaNumber: "8000105", source: .bahnDe)
    private let muenchen = Station(id: "8000261", name: "München Hbf", coordinate: Coordinate(latitude: 48.1402, longitude: 11.5586),
                                   evaNumber: "8000261", source: .bahnDe)

    private func leg(_ name: String, number: String, from: Station, to: Station, departure: String, arrival: String,
                     arrivalDelay: TimeInterval = 0) -> Leg {
        Leg(origin: from, destination: to,
            departure: TimeInfo(planned: date(departure), actual: date(departure).addingTimeInterval(5 * 60)),
            arrival: TimeInfo(planned: date(arrival), actual: date(arrival).addingTimeInterval(arrivalDelay)),
            departurePlatform: nil, arrivalPlatform: nil, tripId: "trip-\(name)",
            line: Line(name: name, number: number, product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    @Test func favouriteStationOpensItsBoard() {
        let entry = SpotlightEntry.station(koeln)
        #expect(entry.kind == .station)
        #expect(entry.title == "Köln Hbf – Abfahrten")
        #expect(entry.subtitle == "Nordrhein-Westfalen")
        #expect(entry.keywords.contains("KK"))
        #expect(entry.expiry == nil)
        #expect(BoardWidgetLink.target(from: entry.url) == .board(koeln))
        #expect(SpotlightEntry.url(forID: entry.id) == entry.url)
    }

    @Test func savedJourneyShowsFirstTrainDestinationAndPlannedDeparture() throws {
        // Friday 14:12 in Berlin, departing 5 minutes late: the entry keeps the planned time.
        let journey = Journey(legs: [
            leg("ICE 597", number: "597", from: koeln, to: frankfurt, departure: "2026-10-23T12:12:00Z", arrival: "2026-10-23T13:16:00Z"),
            leg("ICE 627", number: "627", from: frankfurt, to: muenchen, departure: "2026-10-23T13:50:00Z", arrival: "2026-10-23T17:05:00Z",
                arrivalDelay: 20 * 60),
        ], source: .bahnDe)
        let entry = try #require(SpotlightEntry.journey(journey, now: now, timeZone: berlin))
        #expect(entry.kind == .journey)
        #expect(entry.title == "ICE 597 nach München Hbf, Fr 14:12")
        #expect(entry.subtitle == "Köln Hbf → München Hbf · ICE 597, ICE 627")
        for word in ["ICE 597", "ICE597", "597", "627", "KK", "MH", "Frankfurt(Main)Hbf"] {
            #expect(entry.keywords.contains(word), "missing \(word)")
        }
        // Spotlight drops it 10 minutes after the real arrival, like `Journey.isOver`.
        #expect(entry.expiry == date("2026-10-23T17:35:00Z"))
        #expect(LiveActivityLink.journeyID(from: entry.url) == journey.id)
        #expect(SpotlightEntry.url(forID: entry.id) == entry.url)
    }

    @Test func journeyThatIsOverIsLeftOut() {
        let journey = Journey(legs: [leg("ICE 597", number: "597", from: koeln, to: muenchen,
                                         departure: "2026-10-20T12:12:00Z", arrival: "2026-10-20T17:05:00Z")], source: .bahnDe)
        #expect(SpotlightEntry.journey(journey, now: now, timeZone: berlin) == nil)
        #expect(SpotlightEntry.entries(favorites: [koeln], journeys: [journey], now: now, timeZone: berlin).map(\.kind) == [.station])
        #expect(SpotlightEntry.journey(Journey(legs: [], source: .bahnDe), now: now) == nil)
    }

    @Test func laterDeparturesShowTheDate() {
        #expect(SpotlightEntry.departureText(date("2026-11-06T13:12:00Z"), now: now, timeZone: berlin) == "Fr 06.11. 14:12")
        #expect(SpotlightEntry.departureText(date("2026-10-21T18:30:00Z"), now: now, timeZone: berlin) == "Mi 20:30")
    }

    @Test func removedEntriesAreTheOnesNoLongerThere() {
        let current = [SpotlightEntry.station(koeln)]
        let gone = SpotlightEntry.station(muenchen).id
        #expect(SpotlightEntry.removedIDs(previous: [current[0].id, gone], current: current) == [gone])
    }

    @Test func otherLinksAreNoEntries() {
        #expect(SpotlightEntry.url(forID: "betterbahn://share?data=abc") == nil)
        #expect(SpotlightEntry.url(forID: "not a link") == nil)
    }
}
