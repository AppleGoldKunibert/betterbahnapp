import Foundation
import Testing
@testable import BetterBahnKit

/// Transitous' trip for the Ringbahn (S41/S42) is the vehicle's whole day: the S42 listed 490 stops from
/// 03:51, every station 18 or 19 times. The departure board's "Gesundbrunnen 17:50" then showed the
/// run "ab 3:50" (the first visit), and DB's Timetables was asked about every lap.
@Suite struct TripLapTests {
    // A shortened ring: Gesundbrunnen → Westhafen → Beusselstraße → Schönhauser Allee, every 10 minutes,
    // one lap an hour, four laps from 03:51 (2026-10-09 01:51 UTC).
    let names = ["Gesundbrunnen", "Westhafen", "Beusselstraße", "Schönhauser Allee"]
    let start = Date(timeIntervalSince1970: 1_791_510_660)

    func stop(_ name: String, at minutes: Int) -> Stopover {
        let time = TimeInfo(planned: start.addingTimeInterval(TimeInterval(minutes * 60)), actual: nil)
        return Stopover(station: station("t:\(name)", name, source: .transitous), arrival: time, departure: time,
                        arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    func ring(laps: Int) -> Trip {
        let stops = (0..<laps).flatMap { lap in names.enumerated().map { stop($0.element, at: lap * 60 + $0.offset * 10) } }
        return Trip(id: "ring", line: Line(name: "S42", number: "42", product: .suburban, operatorName: nil, tripNumber: "42005"),
                    direction: "Ringbahn", stopovers: stops, cancelled: false, remarks: [], source: .transitous)
    }

    func minutes(_ stop: Stopover) -> Int { Int(stop.departure!.planned.timeIntervalSince(start) / 60) }

    @Test func departureShowsTheLapOfThatTime() throws {
        let trip = ring(laps: 4)
        let gesundbrunnen = trip.stopovers[0].station
        // The board's 3rd departure from Gesundbrunnen, not the first of the day.
        let lap = try #require(trip.lap(at: gesundbrunnen, near: start.addingTimeInterval(2 * 3600)))

        #expect(lap.stopovers.count == 5)
        #expect(minutes(lap.stopovers.first!) == 120)
        #expect(minutes(lap.stopovers.last!) == 180)
        #expect(lap.stopovers.first?.station.name == "Gesundbrunnen")
        #expect(lap.stopovers.last?.station.name == "Gesundbrunnen")
    }

    @Test func midRingStationStartsAtThatVisit() throws {
        let trip = ring(laps: 4)
        let westhafen = trip.stopovers[1].station
        let lap = try #require(trip.lap(at: westhafen, near: start.addingTimeInterval((60 + 10) * 60)))

        #expect(minutes(lap.stopovers.first!) == 70)
        #expect(lap.stopovers.map(\.station.name) == ["Westhafen", "Beusselstraße", "Schönhauser Allee", "Gesundbrunnen", "Westhafen"])
    }

    @Test func arrivalEndsAtThatVisit() throws {
        let trip = ring(laps: 4)
        let beusselstrasse = trip.stopovers[2].station
        let lap = try #require(trip.lap(at: beusselstrasse, near: start.addingTimeInterval((120 + 20) * 60), arriving: true))

        #expect(minutes(lap.stopovers.last!) == 140)
        #expect(minutes(lap.stopovers.first!) == 80)
        #expect(lap.stopovers.last?.station.name == "Beusselstraße")
    }

    @Test func firstAndLastLapAreCutAtTheTripsEnds() throws {
        let trip = ring(laps: 3)
        let schoenhauser = trip.stopovers[3].station
        // The block's last stop: the lap ending there.
        let last = try #require(trip.lap(at: schoenhauser, near: start.addingTimeInterval((120 + 30) * 60)))
        #expect(minutes(last.stopovers.first!) == 90)
        #expect(minutes(last.stopovers.last!) == 150)

        let first = try #require(trip.lap(at: schoenhauser, near: start.addingTimeInterval(30 * 60), arriving: true))
        #expect(minutes(first.stopovers.first!) == 0)
        #expect(minutes(first.stopovers.last!) == 30)
    }

    @Test func extraLapsAddTheOnesAroundWithoutRepeatingTheJoiningStop() throws {
        let trip = ring(laps: 4)
        let gesundbrunnen = trip.stopovers[0].station
        let time = start.addingTimeInterval(60 * 60)   // the 2nd lap: 60...120

        let one = try #require(trip.lap(at: gesundbrunnen, near: time))
        #expect(one.stopovers.count == 5)
        #expect(one.hasPreviousLap && one.hasNextLap)

        let next = try #require(trip.lap(at: gesundbrunnen, near: time, extraAfter: 1))
        #expect(next.stopovers.count == 9)   // 60...180, Gesundbrunnen at 120 only once
        #expect(next.stopovers.filter { minutes($0) == 120 }.count == 1)
        #expect(minutes(next.stopovers.first!) == 60 && minutes(next.stopovers.last!) == 180)

        let both = try #require(trip.lap(at: gesundbrunnen, near: time, extraBefore: 1, extraAfter: 1))
        #expect(minutes(both.stopovers.first!) == 0 && minutes(both.stopovers.last!) == 180)
        #expect(Set(both.stopovers.map(\.id)).count == both.stopovers.count)
    }

    @Test func noMoreLapsOnceTheBlocksEndsAreReached() throws {
        let trip = ring(laps: 3)
        let gesundbrunnen = trip.stopovers[0].station
        let time = start.addingTimeInterval(60 * 60)

        let everything = try #require(trip.lap(at: gesundbrunnen, near: time, extraBefore: 5, extraAfter: 5))
        #expect(everything.stopovers.count == trip.stopovers.count)
        #expect(!everything.hasPreviousLap && !everything.hasNextLap)

        let firstLap = try #require(trip.lap(at: gesundbrunnen, near: start))
        #expect(!firstLap.hasPreviousLap && firstLap.hasNextLap)
        let lastLap = try #require(trip.lap(at: gesundbrunnen, near: start.addingTimeInterval(2 * 3600), arriving: true))
        #expect(lastLap.hasPreviousLap)
    }

    @Test func tripThatOnlyTurnsRoundKeepsAllItsStops() {
        // Berlin Hbf → Halle → back via Hbf: the station twice, no ring.
        #expect(ring(laps: 2).lap(at: ring(laps: 2).stopovers[0].station, near: start) == nil)
    }

    @Test func unknownStationGivesNothing() {
        #expect(ring(laps: 4).lap(at: station("t:Hamburg", "Hamburg Hbf", source: .transitous), near: start) == nil)
    }
}
