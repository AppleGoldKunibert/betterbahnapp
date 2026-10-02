import Testing
@testable import BetterBahnKit

@Suite struct TrainPositionRefreshTests {
    @Test func automaticSlowsDownWhenSavingData() {
        #expect(TrainPositionRefresh.automatic.interval(savingData: false) == .seconds(15))
        #expect(TrainPositionRefresh.automatic.interval(savingData: true) == .seconds(60))
    }

    @Test func fixedIntervalsIgnoreTheConnection() {
        for refresh in [TrainPositionRefresh.every15Seconds, .every30Seconds, .everyMinute, .every2Minutes] {
            #expect(refresh.interval(savingData: false) == refresh.interval(savingData: true))
        }
        #expect(TrainPositionRefresh.every30Seconds.interval(savingData: true) == .seconds(30))
        #expect(TrainPositionRefresh.every2Minutes.interval(savingData: false) == .seconds(120))
    }

    @Test func offNeverRefreshes() {
        #expect(TrainPositionRefresh.off.interval(savingData: false) == nil)
        #expect(TrainPositionRefresh.off.interval(savingData: true) == nil)
    }
}
