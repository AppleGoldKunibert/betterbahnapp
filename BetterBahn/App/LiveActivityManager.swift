import ActivityKit
import BetterBahnKit
import Foundation
import Observation
import UIKit

/// Projects a single journey onto the (one) Live Activity. State is derived locally from the
/// journey every time `show` is called — `AppModel` is responsible for calling it often enough
/// (see `AppModel.syncLiveActivity`), since ActivityKit gives no way to run our own timer once the
/// app is suspended in the background. While backgrounded, `AppModel.scheduleLiveActivityBackgroundCheck`
/// covers ending a finished journey's activity via a `BGAppRefreshTask` instead, and with push updates on, the
/// `betterbahn-live` Worker keeps it current meanwhile (`AppModel.handOverLiveActivity`, #315).
@Observable
final class LiveActivityManager {
    private(set) var activeJourneyID: String?

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Live Activities exist only on the iPhone: on the iPad and the Mac their settings are hidden.
    static var isSupported: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !ProcessInfo.processInfo.isiOSAppOnMac
    }

    func isActive(_ journey: Journey) -> Bool { activeJourneyID == journey.id }

    /// The push token of the activity for `journeyID` (hex), once ActivityKit has handed it out; only activities
    /// started with push updates get one.
    func pushToken(for journeyID: String) -> String? {
        Activity<TripActivityAttributes>.activities.first { $0.attributes.journeyID == journeyID }?.pushToken.map(LiveActivityPush.hex)
    }

    /// Starts, updates or ends the activity so it matches `journey` (nil ends it). A new activity gets a push
    /// token when `pushUpdates`, so our server can update it while the app is closed.
    func show(_ journey: Journey?, pushUpdates: Bool = false) async {
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
        if state.arrived {
            // Ends it right away, but lets the system keep "Angekommen" up until a few minutes
            // after the arrival, since the app may not get to run again by then.
            let dismissal = state.expectedTime.addingTimeInterval(TripActivityAttributes.arrivedDisplayDuration)
            for activity in Activity<TripActivityAttributes>.activities
            where activity.attributes.journeyID == journey.id && activity.activityState == .active {
                await activity.end(ActivityContent(state: state, staleDate: nil),
                                   dismissalPolicy: dismissal > .now ? .after(dismissal) : .immediate)
            }
            activeJourneyID = journey.id
            return
        }
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
            _ = try? Activity.request(attributes: attributes, content: content, pushType: pushUpdates ? .token : nil)
        }
        activeJourneyID = journey.id
    }

    /// Ends the running activity without forgetting which journey it showed, so the next `show` starts it again:
    /// whether an activity gets push updates is fixed when it starts.
    func restart() async {
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Lights up the running activity with an alert (the exit reminder, #313), keeping its content.
    /// Returns false when no activity is running to show it.
    func alert(title: String, body: String) async -> Bool {
        guard let journeyID = activeJourneyID else { return false }
        var alerted = false
        for activity in Activity<TripActivityAttributes>.activities
        where activity.attributes.journeyID == journeyID && activity.activityState == .active {
            let alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: title),
                                           body: LocalizedStringResource(stringLiteral: body), sound: .default)
            await activity.update(activity.content, alertConfiguration: alert)
            alerted = true
        }
        return alerted
    }

    func endAll() async {
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activeJourneyID = nil
    }
}
