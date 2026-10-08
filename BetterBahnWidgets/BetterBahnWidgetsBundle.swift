import SwiftUI
import WidgetKit

@main
struct BetterBahnWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
        JourneyOverviewWidget()
        CurrentTrainWidget()
        LiveSpeedWidget()
        LivePositionWidget()
    }
}
