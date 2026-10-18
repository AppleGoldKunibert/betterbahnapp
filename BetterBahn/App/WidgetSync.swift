import BetterBahnKit
import Foundation
import WidgetKit

extension AppModel {
    /// The saved journey the home-screen widgets show: the one that is live now (the same one as
    /// the Live Activity), else the next upcoming one, skipping journeys switched off by hand.
    var widgetJourney: SavedJourney? {
        liveJourneyCandidate ?? upcomingJourneys.first { !dismissedLiveActivityJourneyIDs.contains($0.id) }
    }

    /// Hands the widgets the current journey and its trains' positions through the App Group and
    /// reloads them, but only when that changed (WidgetKit limits how often widgets may reload).
    /// `force` writes it anyway, so the widgets' "Stand" moves on (when the app goes to the background).
    func updateWidgets(force: Bool = false) {
        let journey = widgetJourney?.journey
        let trains = Set(journey?.transitLegs.compactMap(\.line?.name) ?? [])
        let positions = trainPositions.filter { trains.contains($0.key) }.mapValues(\.position)
        let snapshot = WidgetSnapshot(journey: journey, trainPositions: positions)
        guard force || !snapshot.hasSameContent(as: lastWidgetSnapshot) else { return }
        lastWidgetSnapshot = snapshot
        WidgetStore.save(snapshot)
        // Only the widgets following the journey; the departure board widget fetches on its own and
        // would spend its reload budget for nothing.
        for kind in WidgetStore.journeyWidgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    /// Hands the departure board widget the stations it can be set to (#314): the favourites and the
    /// routes searched last, whenever they change. The widget's settings read them from the App Group.
    func updateWidgetStations() {
        let stations = WidgetStations(favorites: favoriteStations,
                                      recentRoutes: recentSearches.map { WidgetStations.Route(from: $0.from, to: $0.to) })
        guard stations != lastWidgetStations else { return }
        lastWidgetStations = stations
        WidgetStations.save(stations)
    }
}
