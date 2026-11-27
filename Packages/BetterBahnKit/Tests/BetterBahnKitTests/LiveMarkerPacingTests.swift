import Testing
@testable import BetterBahnKit

@Suite struct LiveMarkerPacingTests {
    @Test func fewMarkersGlideToTheNextStep() {
        let pacing = LiveMarkerPacing.forMarkers(3, lowPower: false)
        #expect(pacing.interval == .seconds(5))
        #expect(pacing.glide == 5)
    }

    @Test func manyMarkersJump() {
        #expect(LiveMarkerPacing.forMarkers(LiveMarkerPacing.maxGlidingMarkers, lowPower: false).glide != nil)
        #expect(LiveMarkerPacing.forMarkers(LiveMarkerPacing.maxGlidingMarkers + 1, lowPower: false).glide == nil)
        #expect(LiveMarkerPacing.forMarkers(150, lowPower: false).interval == .seconds(5))
    }

    @Test func lowPowerModeNeverGlides() {
        #expect(LiveMarkerPacing.forMarkers(1, lowPower: true).glide == nil)
        #expect(LiveMarkerPacing.forMarkers(0, lowPower: true).interval == .seconds(5))
    }
}
