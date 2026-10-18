import AppIntents
import BackgroundTasks
import BetterBahnKit
import CoreSpotlight
import SwiftUI

@main
struct BetterBahnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // Train statistics from one run on, with their raw values (TrainStatisticsRows): launch once with
        // `-debugstats`, stays on until the app is deleted.
        TrainStatistics.enableTestModeIfRequested()
        let model = AppModel()
        _model = State(initialValue: model)
        appDelegate.model = model
        // For the Spotlight entities and their intents (`SpotlightSync`), also when iOS starts the app for one.
        AppDependencyManager.shared.add(dependency: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// Registers the background task that ends the Live Activity while the app is backgrounded –
/// `BGTaskScheduler.register` must run before the app finishes launching, which SwiftUI's `App` protocol
/// gives no hook for on its own –, passes on the APNs device token and opens what a tapped notification is about.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // `using: .main`, not nil: this class is MainActor-isolated by default, so the handler asserts
        // that it runs on the main queue. On BGTaskScheduler's own queue that assertion crashed the app
        // (EXC_BREAKPOINT in `_dispatch_assert_queue_fail`) whenever iOS ran the task.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.liveActivityBackgroundTaskID, using: .main) { [weak self] task in
            guard let model = self?.model, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            model.handleLiveActivityBackgroundTask(refreshTask)
        }
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// The APNs device token for the notifications about followed check-ins (#266).
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model?.didRegisterForPush(deviceToken: FollowedCheckinPush.hex(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model?.didRegisterForPush(deviceToken: nil)
    }

    /// Exit reminders (#313) also show while the app is open; the others don't, as before.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix(AppModel.exitReminderPrefix) ? [.banner, .list, .sound] : [])
    }

    /// A followed user's check-in notification (#266) opens that check-in; the others just open the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let statusID = FollowedCheckinNotifier.statusID(in: response.notification.request.content.userInfo)
        completionHandler()
        guard let statusID else { return }
        Task { @MainActor in await self.model?.openFollowedCheckin(id: statusID) }
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
        .overlay {
            if model.showsTrainSearch {
                TrainSearchOverlay()
                    .tint(.brand)
                    // Appears at once, dimming and bar, so nothing fades from light to dark gray (#229).
                    // Closing still fades out.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        // No animation while opening: a parent animation would still fade the overlay's content in.
        .animation(model.showsTrainSearch ? nil : .snappy, value: model.showsTrainSearch)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.cancelLiveActivityBackgroundCheck()
                Task { await model.takeBackLiveActivity() }
                model.syncLiveActivity()
                model.startRefreshing()
                Task { await model.syncTraewelling() }
                Task { await model.syncFollowedCheckinPush() }
                // Picks up events deleted in the calendar and a switch to full access in iOS Settings.
                model.scheduleCalendarSync()
                // Journeys that ended meanwhile leave the iOS search.
                model.scheduleSpotlightSync()
                // Build the travel map's heatmap in the background so its tab opens instantly.
                model.prewarmTravelMap()
            } else if phase == .background {
                model.stopRefreshing()
                model.scheduleLiveActivityBackgroundCheck()
                model.updateWidgets(force: true)
                withBackgroundTime("LiveActivityHandOver") { await model.handOverLiveActivity() }
            }
        }
        // A followed user's check-in notification was tapped (#266): its list is on the Verbindungen tab.
        .onChange(of: model.followedCheckinToOpen) { _, id in
            guard id != nil else { return }
            incomingSharedJourney = nil
            incomingDBShare = nil
            linkedTrainMap = nil
            selectedTab = .connections
        }
        #if DEBUG
        .task {
            model.seedBrokenTripIfRequested()
            model.seedLateTripsIfRequested()
            model.seedSeatMapTripsIfRequested()
            await model.seedStressTripsIfRequested()
            await model.seedDemoTripsIfRequested()
        }
        #endif
        .onOpenURL(perform: open)
        // A favourite station or saved journey picked in the iOS search (#387).
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let url = SpotlightEntry.url(forID: id) {
                open(url)
            }
        }
        // The same, opened through the entity's intent (`SpotlightSync`).
        .onChange(of: model.linkToOpen, initial: true) { _, url in
            guard let url else { return }
            model.linkToOpen = nil
            open(url)
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

    /// Opens a deep link: from a widget, the Live Activity, Spotlight, a share or a shared journey.
    private func open(_ url: URL) {
        // The departure board widget was tapped: its station's board, or its route in the search (#314).
        if let target = BoardWidgetLink.target(from: url) {
            incomingSharedJourney = nil
            incomingDBShare = nil
            linkedTrainMap = nil
            switch target {
            case .board(let station):
                selectedTab = .departures
                model.boardStationToOpen = station
            case .route(let from, let to):
                selectedTab = .connections
                model.searchToOpen = ConnectionSearch(from: from, to: to, date: .now, isArrival: false,
                                                      onlyValidTicket: model.settings.ticketFilterByDefault)
            }
            return
        }
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
        // The Live Activity or a calendar event was tapped: show its journey (if it's still saved).
        if let journeyID = LiveActivityLink.journeyID(from: url) {
            // Calendar events link by the saved journey's ID, which survives replanning.
            if let entry = model.savedJourneys.first(where: { $0.journey.id == journeyID || $0.id.uuidString == journeyID }) {
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

/// Runs `work` although the app just went to the background: iOS gives it a few more seconds for that.
private func withBackgroundTime(_ name: String, _ work: @escaping @MainActor () async -> Void) {
    let assertion = BackgroundTimeAssertion()
    assertion.id = UIApplication.shared.beginBackgroundTask(withName: name) { assertion.end() }
    Task {
        await work()
        assertion.end()
    }
}

private final class BackgroundTimeAssertion {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
