import ActivityKit
import BetterBahnKit
import Foundation
import Observation

/// Shows the Live Activity for the next saved journey. State is derived locally from the
/// journey while the app runs; push updates come later.
@Observable
final class LiveActivityManager {
    private(set) var activeJourneyID: String?
    private var journey: Journey?
    private var updateTask: Task<Void, Never>?

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
        let content = ActivityContent(state: state, staleDate: staleDate(for: journey))
        if Activity<TripActivityAttributes>.activities.contains(where: { $0.attributes.journeyID == journey.id }) {
            for activity in Activity<TripActivityAttributes>.activities {
                await activity.update(content)
            }
        } else {
            guard areActivitiesEnabled,
                  let origin = journey.legs.first?.origin.name,
                  let destination = journey.legs.last?.destination.name else { return }
            let attributes = TripActivityAttributes(originName: origin, destinationName: destination, journeyID: journey.id)
            _ = try? Activity.request(attributes: attributes, content: content)
        }
        self.journey = journey
        activeJourneyID = journey.id
        startUpdating()
    }

    func endAll() async {
        updateTask?.cancel()
        updateTask = nil
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activeJourneyID = nil
        journey = nil
    }

    private func staleDate(for journey: Journey) -> Date? {
        journey.arrival?.best.addingTimeInterval(15 * 60)
    }

    private func startUpdating() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.tick()
            }
        }
    }

    private func tick() async {
        guard let journey, let state = TripActivityAttributes.ContentState.from(journey) else { return }
        let finished = (journey.arrival?.best ?? .distantFuture).addingTimeInterval(10 * 60) < .now
        for activity in Activity<TripActivityAttributes>.activities {
            if finished {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
            } else if activity.content.state != state {
                await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
            }
        }
        if finished {
            updateTask?.cancel()
            updateTask = nil
            activeJourneyID = nil
            self.journey = nil
        }
    }
}
