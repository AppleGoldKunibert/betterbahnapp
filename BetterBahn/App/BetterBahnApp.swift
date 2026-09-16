import SwiftUI

@main
struct BetterBahnApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

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
        TabView {
            Tab("Verbindungen", systemImage: "arrow.triangle.swap") {
                ConnectionsView()
            }
            Tab("Karte", systemImage: "map.fill") {
                TravelMapView()
            }
            Tab("Abfahrten", systemImage: "clock.arrow.2.circlepath") {
                StationBoardView()
            }
            Tab("Einstellungen", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tint(.brand)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.syncLiveActivity()
                model.startRefreshing()
                Task { await model.syncTraewelling() }
            } else if phase == .background {
                model.stopRefreshing()
            }
        }
        #if DEBUG
        .task {
            model.seedBrokenTripIfRequested()
            await model.seedDemoTripsIfRequested()
        }
        #endif
    }
}
