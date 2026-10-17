import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct YearReviewTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func stop(_ name: String, eva: String? = nil, id: String? = nil, _ lat: Double, _ lon: Double) -> Station {
        Station(id: id ?? eva ?? name, name: name, coordinate: Coordinate(latitude: lat, longitude: lon),
                evaNumber: eva, source: .transitous)
    }

    private let berlin = Station(id: "8011160", name: "Berlin Hbf", coordinate: Coordinate(latitude: 52.525, longitude: 13.369),
                                 evaNumber: "8011160", source: .bahnDe)
    private let hamburg = Station(id: "8002549", name: "Hamburg Hbf", coordinate: Coordinate(latitude: 53.553, longitude: 10.007),
                                  evaNumber: "8002549", source: .bahnDe)
    private let wien = Station(id: "8101003", name: "Wien Hbf", coordinate: Coordinate(latitude: 48.185, longitude: 16.376),
                               evaNumber: "8101003", source: .bahnDe)

    private func ride(_ line: String, _ from: Station, _ to: Station, departure: String, minutes: Double,
                      delay: Int? = nil, night: Bool = false, formation: TrainFormation? = nil) -> YearReview.Ride {
        let start = date(departure)
        let end = start.addingTimeInterval(minutes * 60)
        var trainLine = Line(name: line, number: nil, product: .highSpeed, operatorName: nil)
        trainLine.nightRail = night
        let leg = Leg(origin: from, destination: to,
                      departure: TimeInfo(planned: start, actual: nil),
                      arrival: TimeInfo(planned: end, actual: delay.map { end.addingTimeInterval(Double($0) * 60) }),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: nil, line: trainLine, direction: nil,
                      isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        return YearReview.Ride(leg: leg, formation: formation)
    }

    @Test func countsOnlyRidesOfTheYear() {
        let rides = [
            ride("ICE 1", berlin, hamburg, departure: "2025-12-31T23:30:00Z", minutes: 120), // 1 Jan in Berlin
            ride("ICE 2", hamburg, berlin, departure: "2025-12-31T21:00:00Z", minutes: 120), // still 2025
            ride("ICE 3", berlin, hamburg, departure: "2026-06-01T08:00:00Z", minutes: 90),
        ]
        let review = YearReview(year: 2026, rides: rides, calendar: calendar)
        #expect(review.rides == 2)
        #expect(review.hours == 3.5)
        #expect(review.activeDays == 2)
        #expect(YearReview.years(of: rides.map(\.leg), calendar: calendar) == [2026, 2025])
        #expect(YearReview(year: 2024, rides: rides, calendar: calendar).isEmpty)
    }

    @Test func delayAndPunctualityUseOnlyRidesWithLiveData() {
        let rides = [
            ride("ICE 1", berlin, hamburg, departure: "2026-03-01T08:00:00Z", minutes: 100, delay: 3),
            ride("ICE 2", hamburg, berlin, departure: "2026-03-02T08:00:00Z", minutes: 100, delay: 25),
            ride("ICE 3", berlin, hamburg, departure: "2026-03-03T08:00:00Z", minutes: 100, delay: -2),
            ride("ICE 4", hamburg, berlin, departure: "2026-03-04T08:00:00Z", minutes: 100, delay: 6),
            ride("ICE 5", berlin, hamburg, departure: "2026-03-05T08:00:00Z", minutes: 100),
        ]
        let review = YearReview(year: 2026, rides: rides, calendar: calendar)
        #expect(review.ridesWithDelayData == 4)
        #expect(review.delayMinutes == 34) // the early arrival adds nothing
        #expect(review.punctuality == 0.5) // 6 minutes is late
        #expect(review.mostDelayed == YearReview.Entry(name: "ICE 2", count: 25))
    }

    @Test func routesCountBothDirectionsAndStationsBothEnds() {
        let rides = [
            ride("ICE 1", berlin, hamburg, departure: "2026-03-01T08:00:00Z", minutes: 100),
            ride("ICE 2", hamburg, berlin, departure: "2026-03-02T08:00:00Z", minutes: 100),
            ride("ICE 3", berlin, hamburg, departure: "2026-03-03T08:00:00Z", minutes: 100),
            ride("RJ 4", berlin, wien, departure: "2026-04-03T08:00:00Z", minutes: 500, night: true),
        ]
        let review = YearReview(year: 2026, rides: rides, calendar: calendar)
        #expect(review.routes.first == YearReview.Entry(name: "Berlin Hbf – Hamburg Hbf", count: 3))
        #expect(review.stations.first == YearReview.Entry(name: "Berlin Hbf", count: 4))
        #expect(review.nightTrains == 1)
        #expect(review.countries == ["Deutschland", "Österreich"])
        #expect(review.busiestMonth == YearReview.Entry(name: "3", count: 3))
        #expect(review.longestRide?.to == "Wien Hbf")
        #expect(review.longestRide?.train == "RJ 4")
    }

    @Test func seriesCountOncePerRideAndTrainsetsOnlyWhenRepeated() {
        let double = TrainFormation(units: [TrainFormation.Unit(model: "ICE 4", number: "9001"),
                                            TrainFormation.Unit(model: "ICE 4", number: "9002", name: "Rheinland")])
        let single = TrainFormation(units: [TrainFormation.Unit(model: "ICE 4", number: "9002", name: "Rheinland")])
        let other = TrainFormation(units: [TrainFormation.Unit(model: "ICE 1", number: "101")])
        let rides = [
            ride("ICE 1", berlin, hamburg, departure: "2026-03-01T08:00:00Z", minutes: 100, formation: double),
            ride("ICE 2", hamburg, berlin, departure: "2026-03-02T08:00:00Z", minutes: 100, formation: single),
            ride("ICE 3", berlin, hamburg, departure: "2026-03-03T08:00:00Z", minutes: 100, formation: other),
        ]
        let review = YearReview(year: 2026, rides: rides, calendar: calendar)
        #expect(review.series == [YearReview.Entry(name: "ICE 4", count: 2), YearReview.Entry(name: "ICE 1", count: 1)])
        #expect(review.trainsets == [YearReview.Entry(name: "Tz 9002 „Rheinland“", count: 2)])
    }

    @Test func kilometersFallBackToStopsWithoutGeometry() {
        let leg = ride("ICE 1", berlin, hamburg, departure: "2026-03-01T08:00:00Z", minutes: 100).leg
        let straight = berlin.coordinate!.distance(to: hamburg.coordinate!) / 1000
        #expect(abs(YearReview.Ride(leg: leg).kilometers - straight) < 0.01)
        let detour = [berlin.coordinate!, Coordinate(latitude: 53.0, longitude: 11.0), hamburg.coordinate!]
        #expect(YearReview.Ride(leg: leg, geometry: detour).kilometers > straight)
    }

    @Test func countryFromEvaOrTransitousID() {
        #expect(YearReview.countryCode(of: stop("Wien", eva: "8103000", 0, 0)) == "AT")
        #expect(YearReview.countryCode(of: stop("Berlin", id: "de-DELFI_de:11000:900003201", 0, 0)) == "DE")
        #expect(YearReview.countryCode(of: stop("Bruxelles", id: "be-sncb_8814001", 0, 0)) == "BE")
        #expect(YearReview.countryCode(of: stop("Praha", id: "cz-CZPTT_czptt:stop:CZ:54212", 0, 0)) == "CZ")
        #expect(YearReview.countryCode(of: stop("Děčín", id: "at-Railway-Current-Reference-Data-2026_cz:0:5433295:0:7", 0, 0)) == "CZ")
        #expect(YearReview.countryCode(of: stop("Irgendwo", id: "12345", 0, 0)) == nil)
    }

    @Test func featuredYearInDecemberAndJanuary() {
        #expect(YearReview.featuredYear(on: date("2026-12-10T12:00:00Z"), calendar: calendar) == 2026)
        #expect(YearReview.featuredYear(on: date("2027-01-20T12:00:00Z"), calendar: calendar) == 2026)
        #expect(YearReview.featuredYear(on: date("2026-10-17T12:00:00Z"), calendar: calendar) == nil)
    }
}
