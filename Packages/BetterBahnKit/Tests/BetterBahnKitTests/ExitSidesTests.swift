import Foundation
import Testing
@testable import BetterBahnKit

/// Which side the platform is on where the user gets off (#394).
@Suite struct ExitSidesTests {
    // A made-up station at 50° N 8° E: track 7 runs east-west, track 8 too but ends at a buffer stop in the east.
    let hbf = station("9900001", "Teststadt Hbf", 50.0, 8.0)
    let entries = [
        ExitSides.Entry(name: "Teststadt Hauptbahnhof", ril100: "TST", uic: "9900001", lat: 50.0, lon: 8.0, tracks: [
            ExitSides.Track(track: "7", heading: 90, side: .left),
            ExitSides.Track(track: "8", heading: 90, side: .right, terminal: true),
        ]),
        // The next station 900 m east, with its own track 7 the other way round.
        ExitSides.Entry(name: "Teststadt Ost", lat: 50.0, lon: 8.0126, tracks: [
            ExitSides.Track(track: "7", heading: 90, side: .right),
        ]),
    ]

    func point(east: Double, north: Double) -> Coordinate {
        Coordinate(latitude: 50.0 + north / 110_540, longitude: 8.0 + east / (111_320 * cos(50.0 * .pi / 180)))
    }

    @Test func normalizesTrackNumbers() {
        #expect(ExitSides.normalizedTrack("7 D-G") == "7")
        #expect(ExitSides.normalizedTrack("Gleis 4a") == "4a")
        #expect(ExitSides.normalizedTrack("Gl. 12") == "12")
        #expect(ExitSides.normalizedTrack("07") == "7")
        #expect(ExitSides.normalizedTrack("101") == "101")
        #expect(ExitSides.normalizedTrack("7a-c") == "7a")
        #expect(ExitSides.normalizedTrack("Bus") == nil)
        #expect(ExitSides.normalizedTrack("7ab") == nil)
        #expect(ExitSides.normalizedTrack("") == nil)
    }

    @Test func sideFollowsTheTrainsDirection() {
        // Eastbound the platform of track 7 is on the left, westbound on the right.
        #expect(ExitSides.side(at: hbf, platform: "7", heading: 95, product: .regional, in: entries) == .left)
        #expect(ExitSides.side(at: hbf, platform: "7 A-C", heading: 260, product: .regional, in: entries) == .right)
        // Across the track the direction says nothing.
        #expect(ExitSides.side(at: hbf, platform: "7", heading: 0, product: .regional, in: entries) == nil)
        #expect(ExitSides.side(at: hbf, platform: "7", heading: nil, product: .regional, in: entries) == nil)
        // A dead-end track is always entered the same way.
        #expect(ExitSides.side(at: hbf, platform: "8", heading: nil, product: .regional, in: entries) == .right)
        #expect(ExitSides.side(at: hbf, platform: "8", heading: 270, product: .regional, in: entries) == .right)
        // Unknown track, no platform.
        #expect(ExitSides.side(at: hbf, platform: "9", heading: 90, product: .regional, in: entries) == nil)
        #expect(ExitSides.side(at: hbf, platform: nil, heading: 90, product: .regional, in: entries) == nil)
    }

    @Test func picksTheStationByNumberCodeOrName() {
        // The neighbour's track 7 has the other side: by EVA number the right station is taken …
        #expect(ExitSides.side(at: hbf, platform: "7", heading: 90, product: .regional, in: entries) == .left)
        // … and by name when the stop has none; the neighbour's own stop takes its entry.
        let byName = station("x", "Teststadt Hbf", 50.001, 8.001, source: .transitous)
        #expect(ExitSides.side(at: byName, platform: "7", heading: 90, product: .regional, in: entries) == .left)
        let ost = station("y", "Teststadt Ost", 50.0, 8.0126, source: .transitous)
        #expect(ExitSides.side(at: ost, platform: "7", heading: 90, product: .regional, in: entries) == .right)
        // A station too far away, or with another name, gets nothing.
        let far = station("z", "Teststadt Hbf", 50.05, 8.0, source: .transitous)
        #expect(ExitSides.side(at: far, platform: "7", heading: 90, product: .regional, in: entries) == nil)
        let other = station("w", "Anderswo", 50.0, 8.0, source: .transitous)
        #expect(ExitSides.side(at: other, platform: "7", heading: 90, product: .regional, in: entries) == nil)
    }

    @Test func lightRailStationsServeOnlySBahnTrains() {
        // Only the S-Bahn's own station node knows track 15.
        let light = [ExitSides.Entry(name: "Hauptbahnhof", lat: 50.0003, lon: 8.0, tracks: [ExitSides.Track(track: "15", heading: 90, side: .left)],
                                     light: true)]
        #expect(ExitSides.side(at: hbf, platform: "15", heading: 90, product: .suburban, in: light) == .left)
        #expect(ExitSides.side(at: hbf, platform: "15", heading: 90, product: .regional, in: light) == nil)
        #expect(ExitSides.side(at: hbf, platform: "15", heading: 90, product: nil, in: light) == nil)
    }

    @Test func overridesReplaceTracksOrAddStations() {
        let overrides = [
            ExitSides.Entry(name: "Teststadt Hbf", ril100: "TST", lat: 50.0, lon: 8.0, tracks: [
                ExitSides.Track(track: "7", heading: 90, side: .right),
                ExitSides.Track(track: "9", heading: 0, side: .left),
            ]),
            ExitSides.Entry(name: "Neustadt", lat: 51.0, lon: 9.0, tracks: [ExitSides.Track(track: "1", heading: 0, side: .left)]),
        ]
        let merged = ExitSides.merging(entries, overrides: overrides)
        #expect(merged.count == 3)
        let hbf = merged.first { $0.ril100 == "TST" }
        #expect(hbf?.tracks.map(\.track).sorted() == ["7", "8", "9"])
        #expect(hbf?.tracks.first { $0.track == "7" }?.side == .right)
        #expect(merged.last?.name == "Neustadt")
    }

    @Test func headingComesFromTheGeometryElseThePreviousStop() {
        let stop = point(east: 0, north: 0)
        // The route comes from the west and bends north right at the end: the last 250 m count.
        let route = [point(east: -2000, north: 0), point(east: -600, north: 0), point(east: -300, north: 0), point(east: 0, north: 0)]
        let heading = ExitSides.arrivalHeading(at: stop, along: route, from: point(east: -5000, north: -5000))
        #expect(heading.map { ExitSides.angle($0, 90) < 2 } == true)
        // No geometry near the stop: the previous stop's bearing, unless it is right here.
        #expect(ExitSides.arrivalHeading(at: stop, along: nil, from: point(east: 0, north: -3000)).map { ExitSides.angle($0, 0) < 1 } == true)
        #expect(ExitSides.arrivalHeading(at: stop, along: nil, from: point(east: 50, north: 0)) == nil)
        #expect(ExitSides.arrivalHeading(at: stop, along: nil, from: nil) == nil)
    }

    @Test func legAndTripLookUpTheirExit() {
        let west = station("9900002", "Westdorf", 50.0, 7.9)
        let geometry = [point(east: -7000, north: 0), point(east: -300, north: 0), point(east: 0, north: 0)]
        let time = TimeInfo(planned: Date(timeIntervalSince1970: 1_800_000_000), actual: nil)
        let sBahn = Line(name: "S 1", number: "1", product: .suburban, operatorName: nil)
        var leg = Leg(origin: west, destination: hbf, departure: time, arrival: time, departurePlatform: nil,
                      arrivalPlatform: PlatformInfo(planned: "7", actual: nil), tripId: "t", line: sBahn, direction: nil,
                      isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous, geometry: geometry)
        #expect(ExitSides.side(leaving: leg, in: entries) == .left)
        // The U-Bahn's "2 (U5)" at the same station is not the railway's track 2.
        var uBahn = leg
        uBahn.line = Line(name: "U 5", number: "5", product: .subway, operatorName: nil)
        uBahn.arrivalPlatform = PlatformInfo(planned: "2 (U5)", actual: nil)
        #expect(ExitSides.side(leaving: uBahn, in: entries) == nil)
        leg.line = nil
        #expect(ExitSides.side(leaving: leg, in: entries) == nil)
        leg.line = sBahn
        // Without geometry the previous stop (west of here) gives the direction.
        leg.geometry = nil
        #expect(ExitSides.side(leaving: leg, in: entries) == .left)
        // A platform change moves the exit to the other side of the island.
        leg.arrivalPlatform = PlatformInfo(planned: "7", actual: "8")
        #expect(ExitSides.side(leaving: leg, in: entries) == .right)

        let stops = [Stopover(station: west, arrival: nil, departure: time, arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
                     Stopover(station: hbf, arrival: time, departure: time, arrivalPlatform: PlatformInfo(planned: "7", actual: nil),
                              departurePlatform: nil, cancelled: false)]
        let trip = Trip(id: "t", line: sBahn, direction: nil, stopovers: stops, cancelled: false, remarks: [], source: .transitous,
                        geometry: geometry)
        #expect(ExitSides.side(leaving: trip, at: 1, in: entries) == .left)
        #expect(ExitSides.side(leaving: trip, at: 0, in: entries) == nil)
    }

    @Test func reminderNamesTheSide() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let time = TimeInfo(planned: now.addingTimeInterval(1800), actual: nil)
        let leg = Leg(origin: station("9900002", "Westdorf", 50.0, 7.9), destination: hbf, departure: TimeInfo(planned: now, actual: nil),
                      arrival: time, departurePlatform: nil, arrivalPlatform: PlatformInfo(planned: "7", actual: nil), tripId: "t",
                      line: Line(name: "RE 7", number: "7", product: .regional, operatorName: nil), direction: nil, isWalking: false,
                      cancelled: false, stopovers: [], remarks: [], source: .transitous)
        let journey = Journey(legs: [leg], source: .transitous)
        let withSide = journey.exitReminders(lead: 300, now: now, exitSide: { _ in .left })
        #expect(withSide.first?.body == "In 5 Min. Ankunft am Ziel Teststadt Hbf, Ausstieg links")
        let without = journey.exitReminders(lead: 300, now: now, exitSide: { _ in nil })
        #expect(without.first?.body == "In 5 Min. Ankunft am Ziel Teststadt Hbf")
    }
}
