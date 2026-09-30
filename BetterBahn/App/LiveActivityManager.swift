import ActivityKit
import BetterBahnKit
import Foundation
import Observation

/// Projects a single journey onto the (one) Live Activity. State is derived locally from the
/// journey every time `show` is called — `AppModel` is responsible for calling it often enough
/// (see `AppModel.syncLiveActivity`), since ActivityKit gives no way to run our own timer once the
/// app is suspended in the background. While backgrounded, `AppModel.scheduleLiveActivityBackgroundCheck`
/// covers ending a finished journey's activity via a `BGAppRefreshTask` instead.
@Observable
final class LiveActivityManager {
    private(set) var activeJourneyID: String?

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isActive(_ journey: Journey) -> Bool { activeJourneyID == journey.id }

    /// Starts, updates or ends the activity so it matches `journey` (nil ends it).
    func show(_ journey: Journey?) async {
        guard let journey, let state = TripActivityAttributes.ContentState.from(journey) else {
            await endAll()
            return
        }
        // End activities for other journeys.
        for activity in Activity<TripActivityAttributes>.activities where activity.attributes.journeyID != journey.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        // Goes stale when the state itself expects to change (the next departure/arrival). The system
        // re-renders the activity then, and the widget shows `state.followUp`, so it moves on even
        // if the app doesn't get a chance to refresh it in time.
        let content = ActivityContent(state: state, staleDate: state.followUpDate)
        if Activity<TripActivityAttributes>.activities.contains(where: { $0.attributes.journeyID == journey.id }) {
            for activity in Activity<TripActivityAttributes>.activities
            where activity.attributes.journeyID == journey.id && activity.content.state != state {
                await activity.update(content)
            }
        } else {
            guard areActivitiesEnabled,
                  let origin = journey.legs.first?.origin.displayName,
                  let destination = journey.legs.last?.destination.displayName else { return }
            let attributes = TripActivityAttributes(originName: origin, destinationName: destination, journeyID: journey.id)
            _ = try? Activity.request(attributes: attributes, content: content)
        }
        activeJourneyID = journey.id
    }

    func endAll() async {
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activeJourneyID = nil
    }
}
