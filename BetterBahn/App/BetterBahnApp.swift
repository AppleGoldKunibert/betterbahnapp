import BackgroundTasks
import BetterBahnKit
import SwiftUI

@main
struct BetterBahnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        appDelegate.model = model
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// Only exists to register the background task that ends the Live Activity while the app is
/// backgrounded (`BGTaskScheduler.register` must run before the app finishes launching, which
/// SwiftUI's `App` protocol gives no hook for on its own).
final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.liveActivityBackgroundTaskID, using: nil) { [weak self] task in
            guard let model = self?.model, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            model.handleLiveActivityBackgroundTask(refreshTask)
        }
        return true
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var incomingSharedJourney: Journey?
    @State private var incomingDBShare: DBShareText?
    @State private var showInvalidShareLinkAlert = false
    @State private var shareLinkError: String?
    /// A train's live map opened from a widget (`TrainMapLink`).
    @State private var linkedTrainMap: LinkedTrainMap?
    @State private var selectedTab = RootTab.connections

    enum RootTab: Hashable {
        case connections, map, departures, settings
    }

    var body: some View {
        #if DEBUG
        if let screen = DebugScreen.requested {
            DebugScreen(name: screen)
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Verbindungen", systemImage: "arrow.triangle.swap", value: .connections) {
                ConnectionsView()
            }
            Tab("Karte", systemImage: "map.fill", value: .map) {
                TravelMapView()
            }
            Tab("Abfahrten", systemImage: "clock.arrow.2.circlepath", value: .departures) {
                StationBoardView()
            }
            Tab("Einstellungen", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
        .tint(.brand)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.cancelLiveActivityBackgroundCheck()
                model.syncLiveActivity()
                model.startRefreshing()
                Task { await model.syncTraewelling() }
                // Build the travel map's heatmap in the background so its tab opens instantly.
                model.prewarmTravelMap()
            } else if phase == .background {
                model.stopRefreshing()
                model.scheduleLiveActivityBackgroundCheck()
                model.updateWidgets(force: true)
                Task { await TrainSightings.shared.flush() }
            }
        }
        #if DEBUG
        .task {
            model.seedBrokenTripIfRequested()
            await model.seedStressTripsIfRequested()
            await model.seedDemoTripsIfRequested()
        }
        #endif
        .onOpenURL { url in
            // A live widget was tapped: show its train on the live map.
            if let target = TrainMapLink.target(from: url) {
                if let entry = model.savedJourneys.first(where: { $0.journey.id == target.journeyID }),
                   entry.journey.legs.indices.contains(target.legIndex) {
                    incomingSharedJourney = nil
                    incomingDBShare = nil
                    linkedTrainMap = LinkedTrainMap(route: LiveTrainRoute(leg: entry.journey.legs[target.legIndex]))
                }
                return
            }
            // The Live Activity was tapped: show its journey (if it's still saved).
            if let journeyID = LiveActivityLink.journeyID(from: url) {
                if let entry = model.savedJourneys.first(where: { $0.journey.id == journeyID }) {
                    incomingSharedJourney = nil
                    incomingDBShare = nil
                    selectedTab = .connections
                    model.journeyToOpen = entry
                }
                return
            }
            // A connection shared from the DB Navigator / bahn.de, handed over by the share extension.
            if let text = DBShare.text(fromAppURL: url) {
                incomingSharedJourney = nil
                incomingDBShare = DBShareText(text: text)
                return
            }
            // A short link (`https://…/s/<id>` as Universal Link, or the fallback page's button):
            // the journey is fetched from BetterBahn's Worker.
            if let id = JourneyShareLink.shortLinkID(from: url) {
                Task { await openShortShareLink(id: id) }
                return
            }
            guard let journey = JourneyShareLink.journey(from: url) else {
                showInvalidShareLinkAlert = true
                return
            }
            incomingDBShare = nil
            incomingSharedJourney = journey
        }
        .sheet(item: $incomingSharedJourney) { SharedJourneyPreviewView(journey: $0) }
        .sheet(item: $incomingDBShare) { ImportedJourneyView(text: $0.text) }
        .sheet(item: $linkedTrainMap) { LiveTrainMapView(route: $0.route) }
        .alert("Reise-Link ungültig", isPresented: $showInvalidShareLinkAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Dieser Link funktioniert leider nicht.")
        }
        .alert("Reise nicht geladen", isPresented: Binding(get: { shareLinkError != nil },
                                                           set: { if !$0 { shareLinkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareLinkError ?? "")
        }
    }

    private func openShortShareLink(id: String) async {
        do {
            let journey = try await ShortShareLinkClient().journey(id: id)
            incomingDBShare = nil
            incomingSharedJourney = journey
        } catch let error as ShortShareLinkError {
            shareLinkError = error.localizedDescription
        } catch {
            shareLinkError = "Die Reise konnte nicht geladen werden. Prüf deine Internetverbindung und öffne den Link noch einmal."
        }
    }
}

/// A train's live map to open from a widget link.
private struct LinkedTrainMap: Identifiable {
    let id = UUID()
    let route: LiveTrainRoute
}
