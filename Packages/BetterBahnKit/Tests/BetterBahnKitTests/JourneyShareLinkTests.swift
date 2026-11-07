import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct JourneyShareLinkTests {
    @Test func roundTripsAJourney() throws {
        let journey = Self.journey()
        let url = try #require(JourneyShareLink.url(for: journey))
        #expect(JourneyShareLink.journey(from: url) == journey)
    }

    static func journey() -> Journey {
        let departure = Date(timeIntervalSince1970: 1_790_000_000)
        let leg = Leg(origin: station("8002549", "Hamburg Hbf"), destination: station("8010085", "Dresden Hbf"),
                      departure: TimeInfo(planned: departure, actual: nil),
                      arrival: TimeInfo(planned: departure.addingTimeInterval(4 * 3600), actual: nil),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "trip",
                      line: Line(name: "ICE 171", number: "171", product: .highSpeed, operatorName: nil),
                      direction: "Dresden Hbf", isWalking: false, cancelled: false, stopovers: [], remarks: [],
                      source: .transitous)
        return Journey(legs: [leg], source: .transitous)
    }

    @Test func recognizesShortLinks() {
        #expect(JourneyShareLink.shortLinkID(from: URL(string: "https://betterbahn.betterbahn.workers.dev/s/Ab3xK9zz")!) == "Ab3xK9zz")
        #expect(JourneyShareLink.shortLinkID(from: URL(string: "betterbahn://share?id=Ab3xK9zz")!) == "Ab3xK9zz")
        #expect(JourneyShareLink.shortLinkID(from: URL(string: "https://example.com/s/Ab3xK9zz")!) == nil)
        #expect(JourneyShareLink.shortLinkID(from: URL(string: "http://betterbahn.betterbahn.workers.dev/s/Ab3xK9zz")!) == nil)
        #expect(JourneyShareLink.shortLinkID(from: URL(string: "https://betterbahn.betterbahn.workers.dev/s/Ab3xK9")!) == nil)
        #expect(JourneyShareLink.shortLinkID(from: URL(string: "https://betterbahn.betterbahn.workers.dev/s/Ab3x-9zz")!) == nil)
        #expect(JourneyShareLink.shortLinkID(from: URL(string: "https://betterbahn.betterbahn.workers.dev/datenschutz")!) == nil)
        #expect(JourneyShareLink.shortLinkID(from: URL(string: "betterbahn://share?data=abc")!) == nil)
    }

    /// Raw DEFLATE as other zlibs write it (Python's, the Workers') inflates the same on iOS and Android, and
    /// what the app writes comes back unchanged.
    @Test func rawDeflateMatchesZlib() throws {
        let fromZlib = try #require(Data(base64Encoded: "q1ZKK8rPVbJS8j68LSdPwSMpTUlHqSQfKOB7eE9eckYqRKy2msrqAA=="))
        let text = String(repeating: #"{"from":"Köln Hbf","to":"München Hbf"}"#, count: 3)
        #expect(RawDeflate.inflate(fromZlib, limit: 1024) == Data(text.utf8))
        #expect(RawDeflate.inflate(fromZlib, limit: 10) == nil)
        #expect(RawDeflate.inflate(fromZlib.prefix(10), limit: 1024) == nil)
        #expect(RawDeflate.inflate(Data([0xFF, 0xFF, 0xFF]), limit: 1024) == nil)

        let json = Data(String(repeating: "Frankfurt (Main) Hbf → Berlin Hbf, ", count: 500).utf8)
        let deflated = try #require(RawDeflate.deflate(json))
        #expect(deflated.count < json.count / 10)
        #expect(RawDeflate.inflate(deflated, limit: json.count) == json)
    }

    /// A few kilobytes that would inflate to megabytes are refused instead of decompressed.
    @Test func refusesPayloadsThatInflateTooFar() throws {
        let huge = Data(repeating: UInt8(ascii: " "), count: 8 * 1024 * 1024)
        let compressed = try #require(RawDeflate.deflate(huge))
        #expect(compressed.count < JourneyShareLink.maxEncodedLength)
        #expect(JourneyShareLink.inflate(compressed) == nil)

        let encoded = compressed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(JourneyShareLink.journey(from: URL(string: "betterbahn://share?data=\(encoded)")!) == nil)
        #expect(JourneyShareLink.journey(from: URL(string: "betterbahn://share?data=\(String(repeating: "A", count: 70_000))")!) == nil)
    }
}
