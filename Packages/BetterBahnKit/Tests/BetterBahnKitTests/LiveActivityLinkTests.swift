import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct LiveActivityLinkTests {
    @Test func roundTripsJourneyIDsWithSpecialCharacters() {
        let id = "¶HKI¶T$A=1@O=Berlin Hbf@L=8011160@a=128@$202609301200$ICE 123&x=1#"
        let url = LiveActivityLink.url(journeyID: id)
        #expect(url.scheme == "betterbahn")
        #expect(LiveActivityLink.journeyID(from: url) == id)
    }

    @Test func ignoresOtherLinks() {
        #expect(LiveActivityLink.journeyID(from: URL(string: "betterbahn://share?data=abc")!) == nil)
        #expect(LiveActivityLink.journeyID(from: URL(string: "betterbahn://journey")!) == nil)
        #expect(LiveActivityLink.journeyID(from: URL(string: "https://journey?id=1")!) == nil)
    }
}
