import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct JourneyShareLinkTests {
    @Test func roundTripsAJourney() throws {
        let departure = Date(timeIntervalSince1970: 1_790_000_000)
        let leg = Leg(origin: station("8002549", "Hamburg Hbf"), destination: station("8010085", "Dresden Hbf"),
                      departure: TimeInfo(planned: departure, actual: nil),
                      arrival: TimeInfo(planned: departure.addingTimeInterval(4 * 3600), actual: nil),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "trip",
                      line: Line(name: "ICE 171", number: "171", product: .highSpeed, operatorName: nil),
                      direction: "Dresden Hbf", isWalking: false, cancelled: false, stopovers: [], remarks: [],
                      source: .transitous)
        let journey = Journey(legs: [leg], source: .transitous)
        let url = try #require(JourneyShareLink.url(for: journey))
        #expect(JourneyShareLink.journey(from: url) == journey)
    }

    /// A few kilobytes that would inflate to megabytes are refused instead of decompressed.
    @Test func refusesPayloadsThatInflateTooFar() throws {
        let huge = Data(repeating: UInt8(ascii: " "), count: 8 * 1024 * 1024)
        let compressed = try #require(try (huge as NSData).compressed(using: .zlib) as Data)
        #expect(compressed.count < JourneyShareLink.maxEncodedLength)
        #expect(JourneyShareLink.inflate(compressed) == nil)

        let encoded = compressed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(JourneyShareLink.journey(from: URL(string: "betterbahn://share?data=\(encoded)")!) == nil)
        #expect(JourneyShareLink.journey(from: URL(string: "betterbahn://share?data=\(String(repeating: "A", count: 70_000))")!) == nil)
    }
}
