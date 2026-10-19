import Foundation
import Testing
@testable import BetterBahnKit

/// A run opened from a journey's leg takes the leg's live data where it has none (`Trip.takingLiveData(from:)`).
@Suite struct TripLiveDataTests {
    let berlin = station("8011160", "Berlin Hbf", 52.525, 13.369)
    let halle = station("8010159", "Halle (Saale) Hbf", 51.477, 11.987)
    let frankfurt = station("8000105", "Frankfurt (Main) Hbf", 50.107, 8.663)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func time(_ minutes: Double, delay: Double? = nil) -> TimeInfo {
        let planned = base.addingTimeInterval(minutes * 60)
        return TimeInfo(planned: planned, actual: delay.map { planned.addingTimeInterval($0 * 60) })
    }

    @Test func fillsTimesAndPlatformsTheRunLacks() {
        // The feed's run: planned only, Halle without a platform.
        let run = Trip(id: "ice279", line: nil, direction: nil, stopovers: [
            Stopover(station: berlin, arrival: nil, departure: time(0), arrivalPlatform: nil,
                     departurePlatform: PlatformInfo(planned: "3", actual: nil), cancelled: false),
            Stopover(station: halle, arrival: time(68), departure: time(70), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: frankfurt, arrival: time(241), departure: time(247), arrivalPlatform: PlatformInfo(planned: "7", actual: nil),
                     departurePlatform: nil, cancelled: false),
        ], cancelled: false, remarks: [], source: .transitous)
        // The journey's leg: refreshed with DB's delays, Halle's platform, and its ends ahead of its stopovers.
        let leg = Leg(origin: berlin, destination: frankfurt, departure: time(0, delay: 3), arrival: time(241, delay: 18),
                      departurePlatform: PlatformInfo(planned: "3", actual: nil), arrivalPlatform: PlatformInfo(planned: "7", actual: "9"),
                      tripId: "ice279", line: nil, direction: nil, isWalking: false, cancelled: false, stopovers: [
                          Stopover(station: berlin, arrival: nil, departure: time(0, delay: 2), arrivalPlatform: nil,
                                   departurePlatform: nil, cancelled: false),
                          Stopover(station: halle, arrival: time(68, delay: 5), departure: time(70, delay: 4),
                                   arrivalPlatform: PlatformInfo(planned: "6", actual: nil), departurePlatform: PlatformInfo(planned: "6", actual: nil),
                                   cancelled: false),
                      ], remarks: [], source: .transitous)
        let merged = run.takingLiveData(from: leg)
        // The stopover's delay comes first, the leg's end only fills what is still missing.
        #expect(merged.stopovers[0].departure?.delayMinutes == 2)
        #expect(merged.stopovers[1].arrival?.delayMinutes == 5)
        #expect(merged.stopovers[1].departure?.delayMinutes == 4)
        #expect(merged.stopovers[1].arrivalPlatform?.best == "6")
        #expect(merged.stopovers[2].arrival?.delayMinutes == 18)
        // A platform the run has stays as the run says, even with a change on the leg.
        #expect(merged.stopovers[2].arrivalPlatform?.best == "7")
        // The departure after the leg's end is none of the leg's business.
        #expect(merged.stopovers[2].departure?.actual == nil)
    }

    @Test func keepsTheRunsOwnLiveDataAndOtherTimes() {
        let run = Trip(id: "ice279", line: nil, direction: nil, stopovers: [
            Stopover(station: berlin, arrival: nil, departure: time(0, delay: 1), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            // Another run of the day at Halle: planned times differ, so nothing is taken over.
            Stopover(station: halle, arrival: time(120), departure: time(122), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
        ], cancelled: false, remarks: [], source: .transitous)
        let leg = Leg(origin: berlin, destination: halle, departure: time(0, delay: 7), arrival: time(68, delay: 9),
                      departurePlatform: nil, arrivalPlatform: PlatformInfo(planned: "6", actual: nil), tripId: "ice279", line: nil,
                      direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        let merged = run.takingLiveData(from: leg)
        #expect(merged.stopovers[0].departure?.delayMinutes == 1)
        #expect(merged.stopovers[1].arrival?.actual == nil)
        #expect(merged.stopovers[1].arrivalPlatform == nil)
    }
}
