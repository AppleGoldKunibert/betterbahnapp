import Foundation
import Testing
@testable import BetterBahnKit

/// Lifts out of order from DB's FaSta API at a station and on a journey (#486).
@Suite struct LiftCheckTests {
    /// A made-up station: tracks 4 and 5 share a platform running north with a lift 100 m along it, track 1's
    /// platform is 70 m west with a lift 50 m along it.
    static let eva = "9999001"
    static let platforms = StationPlatforms(sharedPlatforms: [["4", "5"]], tracks: [
        "1": .init(start: Coordinate(latitude: 50.5540, longitude: 9.6830), end: Coordinate(latitude: 50.5560, longitude: 9.6830),
                   length: 222, accesses: [.init(kind: .lift, position: 50)]),
        "4": .init(start: Coordinate(latitude: 50.5540, longitude: 9.6840), end: Coordinate(latitude: 50.5560, longitude: 9.6840),
                   length: 222, accesses: [.init(kind: .lift, position: 100)]),
        "5": .init(start: Coordinate(latitude: 50.5540, longitude: 9.68405), end: Coordinate(latitude: 50.5560, longitude: 9.68405),
                   length: 222, accesses: [.init(kind: .lift, position: 100)]),
    ])
    let platformsAt: (String) -> StationPlatforms? = { $0 == LiftCheckTests.eva ? LiftCheckTests.platforms : nil }

    let fulda = station(LiftCheckTests.eva, "Fulda", 50.555, 9.6835)
    let frankfurt = station("9999002", "Frankfurt (Main) Hbf")
    let berlin = station("9999003", "Berlin Hbf")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// "zu Gleis 4/5" on the platform of 4 and 5.
    let toFour = BrokenLift(id: 1, description: "zu Gleis 4/5", coordinate: Coordinate(latitude: 50.5549, longitude: 9.6840))
    /// No track in its description, but where OSM draws track 1's lift.
    let onOne = BrokenLift(id: 2, description: "Bahnsteig West", coordinate: Coordinate(latitude: 50.55445, longitude: 9.6830),
                           reason: "under maintenance")
    let farAway = BrokenLift(id: 3, description: "zu Gleis 1", coordinate: Coordinate(latitude: 50.60, longitude: 9.70))
    let nowhere = BrokenLift(id: 4, description: "zu Gleis 1", coordinate: nil)
    var lifts: [BrokenLift] { [farAway, onOne, toFour, nowhere] }

    func time(_ minutes: Double) -> TimeInfo { TimeInfo(planned: now.addingTimeInterval(minutes * 60), actual: nil) }

    func leg(_ name: String, _ from: Station, _ to: Station, dep: Double, arr: Double,
             depTrack: String? = nil, arrTrack: String? = nil) -> Leg {
        Leg(origin: from, destination: to, departure: time(dep), arrival: time(arr),
            departurePlatform: depTrack.map { PlatformInfo(planned: $0, actual: nil) },
            arrivalPlatform: arrTrack.map { PlatformInfo(planned: $0, actual: nil) },
            tripId: "trip-\(name)", line: Line(name: name, number: "1", product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    func journey(arriving: String, departing: String) -> Journey {
        Journey(legs: [
            leg("ICE 1000", frankfurt, fulda, dep: 0, arr: 30, arrTrack: arriving),
            leg("ICE 578", fulda, berlin, dep: 40, arr: 200, depTrack: departing),
        ], source: .bahnDe)
    }

    @Test func parsesOnlyLiftsOutOfOrderWithFaStasCoordinates() throws {
        let json = """
        [{"equipmentnumber": 10, "type": "ELEVATOR", "description": "zu Gleis 4/5", "geocoordX": 9.684, "geocoordY": 50.5549,
          "state": "INACTIVE", "stateExplanation": "not available", "stationnumber": 1866},
         {"equipmentnumber": 11, "type": "ELEVATOR", "description": "zu Gleis 1", "geocoordX": 0, "geocoordY": 0, "state": "INACTIVE"},
         {"equipmentnumber": 12, "type": "ESCALATOR", "description": "zu Gleis 2", "state": "INACTIVE"},
         {"equipmentnumber": 13, "type": "ELEVATOR", "description": "zu Gleis 3", "state": "ACTIVE"},
         {"type": "ELEVATOR", "state": "INACTIVE"}]
        """
        let lifts = try FacilityClient.parse(Data(json.utf8))
        #expect(lifts.map(\.id) == [10, 11])
        #expect(lifts[0].coordinate == Coordinate(latitude: 50.5549, longitude: 9.684))
        #expect(lifts[0].reasonText == nil)
        #expect(lifts[1].coordinate == nil)
        #expect(throws: (any Error).self) { try FacilityClient.parse(Data("{\"error\": 1}".utf8)) }
    }

    @Test func readsTracksFromDBsDescription() {
        #expect(LiftCheck.describedTracks("zu Gleis 4/5") == ["4", "5"])
        #expect(LiftCheck.describedTracks("Zugang Gleis 1-3") == ["1", "2", "3"])
        #expect(LiftCheck.describedTracks("zu Gl. 11 und 12 (S-Bahn)") == ["11", "12"])
        #expect(LiftCheck.describedTracks("zu Gleis 3a") == ["3a"])
        #expect(LiftCheck.describedTracks("zur Unterführung").isEmpty)
        #expect(LiftCheck.describedTracks("zu Gleis 101/102, Gleis 104") == ["101", "102", "104"])
    }

    @Test func findsTheStationsLiftsByTheirPlatforms() {
        let alerts = LiftCheck.alerts(at: fulda, among: lifts, platformsAt: platformsAt)
        #expect(alerts.map(\.id) == [2, 1])
        #expect(alerts[0].tracks == ["1"])
        #expect(alerts[1].tracks == ["4", "5"])
        #expect(alerts[1].serves(track: "5 D-F"))
        #expect(!alerts[1].serves(track: "1"))
    }

    @Test func aLiftForOneTrackServesTheWholePlatform() {
        let toFourOnly = BrokenLift(id: 5, description: "zu Gleis 4", coordinate: toFour.coordinate)
        let alerts = LiftCheck.alerts(at: fulda, among: [toFourOnly], platformsAt: platformsAt)
        #expect(alerts.first?.tracks == ["4", "5"])
    }

    @Test func withoutPlatformsOnlyLiftsCloseToTheStationCount() {
        let alerts = LiftCheck.alerts(at: fulda, among: lifts, platformsAt: { _ in nil })
        #expect(Set(alerts.map(\.id)) == [1, 2])
        #expect(alerts.first { $0.id == 2 }?.tracks.isEmpty == true)
        #expect(LiftCheck.alerts(at: frankfurt, among: lifts, platformsAt: platformsAt).isEmpty)
    }

    @Test func saysWhichLiftAndWhy() {
        #expect(LiftAlert(lift: toFour, tracks: ["4", "5"]).text == "Aufzug zu Gleis 4/5 außer Betrieb")
        #expect(LiftAlert(lift: onOne, tracks: ["1"]).text == "Aufzug wegen Wartung außer Betrieb: Bahnsteig West")
        #expect(LiftAlert(lift: BrokenLift(id: 6, description: "", coordinate: nil), tracks: ["7"]).text
            == "Aufzug zu Gleis 7 außer Betrieb")
    }

    @Test func aTransferToAnotherPlatformNeedsBothLifts() {
        let trip = journey(arriving: "1", departing: "4")
        let alerts = trip.liftAlerts(among: lifts, now: now, platformsAt: platformsAt)
        #expect(alerts.map(\.alert.id) == [2, 1])
        #expect(alerts.allSatisfy { $0.place == .transfer && $0.legID == trip.legs[0].id })
        #expect(alerts[1].title == "Aufzug defekt in Fulda")
        #expect(alerts[1].message == "Aufzug zu Gleis 4/5 außer Betrieb. Du steigst hier um.")
    }

    @Test func aTransferAcrossTheSamePlatformNeedsNoLift() {
        #expect(journey(arriving: "4", departing: "5").liftAlerts(among: lifts, now: now, platformsAt: platformsAt).isEmpty)
        #expect(journey(arriving: "4", departing: "4").liftAlerts(among: lifts, now: now, platformsAt: { _ in nil }).isEmpty)
    }

    @Test func startAndDestinationCountTooWhileAhead() {
        let trip = Journey(legs: [leg("RE 1", fulda, berlin, dep: 10, arr: 60, depTrack: "5")], source: .bahnDe)
        let start = trip.liftAlerts(among: lifts, now: now, platformsAt: platformsAt)
        #expect(start.map(\.place) == [.start])
        #expect(start.first?.message == "Aufzug zu Gleis 4/5 außer Betrieb. Hier fährst du los.")
        #expect(trip.liftAlerts(among: lifts, now: now.addingTimeInterval(20 * 60), platformsAt: platformsAt).isEmpty)

        let back = Journey(legs: [leg("RE 2", berlin, fulda, dep: 10, arr: 60, arrTrack: "1")], source: .bahnDe)
        #expect(back.liftAlerts(among: lifts, now: now, platformsAt: platformsAt).map(\.place) == [.destination])
        #expect(back.liftAlerts(among: lifts, now: now.addingTimeInterval(2 * 3600), platformsAt: platformsAt).isEmpty)
    }

    @Test func unknownTracksSayNothing() {
        let trip = Journey(legs: [leg("RE 1", fulda, berlin, dep: 10, arr: 60)], source: .bahnDe)
        #expect(trip.liftAlerts(among: lifts, now: now, platformsAt: platformsAt).isEmpty)
    }

    @Test func exitReminderNamesTheBrokenLift() {
        let trip = journey(arriving: "1", departing: "4")
        let alerts = trip.liftAlerts(among: lifts, now: now, platformsAt: platformsAt)
        let reminder = trip.exitReminders(lead: 5 * 60, now: now, exitSide: { _ in nil }, liftAlerts: alerts).first
        #expect(reminder?.body == "In 5 Min. Ankunft in Fulda – Umstieg in ICE 578, in 10 Min. auf Gl. 4. "
            + "Aufzug wegen Wartung außer Betrieb: Bahnsteig West. Aufzug zu Gleis 4/5 außer Betrieb")
    }
}
