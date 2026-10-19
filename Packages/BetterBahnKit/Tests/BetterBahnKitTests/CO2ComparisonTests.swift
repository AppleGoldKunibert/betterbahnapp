import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct CO2ComparisonTests {
    private let berlin = Station(id: "8011160", name: "Berlin Hbf", coordinate: Coordinate(latitude: 52.525, longitude: 13.369),
                                 evaNumber: "8011160", source: .bahnDe)
    private let hamburg = Station(id: "8002549", name: "Hamburg Hbf", coordinate: Coordinate(latitude: 53.553, longitude: 10.007),
                                  evaNumber: "8002549", source: .bahnDe)

    private func leg(_ product: Product?, walking: Bool = false, departure: Date = Date(timeIntervalSince1970: 1_780_000_000)) -> Leg {
        Leg(origin: berlin, destination: hamburg,
            departure: TimeInfo(planned: departure, actual: nil),
            arrival: TimeInfo(planned: departure.addingTimeInterval(6_000), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: nil,
            line: product.map { Line(name: "Zug", number: nil, product: $0, operatorName: nil) }, direction: nil,
            isWalking: walking, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    @Test func distanceTimesFactorPerProduct() {
        let comparison = CO2Comparison(rides: [(leg(.highSpeed), 300), (leg(.regional), 50), (leg(.bus), 10)])
        #expect(comparison.kilometers == 360)
        #expect(abs(comparison.train - 10.9) < 0.0001) // 300 × 26 g + 50 × 44 g + 10 × 90 g
        #expect(abs(comparison.car - 59.04) < 0.0001) // 360 × 164 g
        #expect(abs(comparison.plane - 104.4) < 0.0001) // 360 × 290 g
        #expect(abs(comparison.savedComparedToCar - 48.14) < 0.0001)
        #expect(abs(comparison.savedComparedToPlane - 93.5) < 0.0001)
    }

    @Test func leavesOutWalksFerriesAndUnknownProducts() {
        let comparison = CO2Comparison(rides: [(leg(.longDistance), 100), (leg(nil, walking: true), 1),
                                               (leg(.ferry), 20), (leg(nil), 30)])
        #expect(comparison.kilometers == 100)
        #expect(abs(comparison.train - 2.6) < 0.0001)
    }

    @Test func emptyTripSavesNothing() {
        let comparison = CO2Comparison(rides: [])
        #expect(comparison.kilometers == 0)
        #expect(comparison.savedComparedToCar == 0)
        #expect(comparison.savedComparedToPlane == 0)
    }

    @Test func measuresLegsAlongTheirGeometryElseTheStraightLine() {
        let train = leg(.highSpeed)
        let straight = CO2Comparison(legs: [train])
        #expect(straight.kilometers > 250 && straight.kilometers < 260) // Berlin–Hamburg as the crow flies
        let detour = [berlin.coordinate!, Coordinate(latitude: 53.0, longitude: 11.0), hamburg.coordinate!]
        let alongTracks = CO2Comparison(legs: [train], geometries: [train.id: detour])
        #expect(alongTracks.kilometers > straight.kilometers)
    }

    @Test func yearReviewAddsUpTheYear() {
        let rides = [YearReview.Ride(leg: leg(.highSpeed)), YearReview.Ride(leg: leg(.regional))]
        let review = YearReview(year: Calendar.current.component(.year, from: rides[0].leg.departure.planned), rides: rides)
        let kilometers: Double = rides[0].kilometers
        let train: Double = kilometers * 0.070 // 26 g + 44 g
        let car: Double = kilometers * 2 * 0.164
        #expect(abs(review.co2.train - train) < 0.0001)
        #expect(abs(review.co2.car - car) < 0.0001)
    }
}
