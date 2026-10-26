import SwiftUI

/// A tab's navigation stack that becomes two columns on the iPad and the Mac (regular width): the tab's first page
/// stays on the left and everything it opens is pushed on the right. On the iPhone it's a plain `NavigationStack`.
///
/// Links on the first page are `RouteLink`s: on the left they replace the right column's path, elsewhere they are
/// plain `NavigationLink(value:)`s.
struct SplitNavigationStack<Route: Hashable, Root: View, Destination: View, Placeholder: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var path: [Route]
    @ViewBuilder var root: () -> Root
    @ViewBuilder var destination: (Route) -> Destination
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                NavigationStack {
                    root()
                        // The search stays visible: hiding it would leave nothing to open from.
                        .toolbar(removing: .sidebarToggle)
                }
                .environment(\.openSplitRoute, SplitRouteAction { value in
                    if let route = value.base as? Route { path = [route] }
                })
                .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 460)
            } detail: {
                NavigationStack(path: $path) {
                    placeholder()
                        .navigationDestination(for: Route.self, destination: destination)
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: $path) {
                root()
                    .navigationDestination(for: Route.self, destination: destination)
            }
        }
    }
}

/// Opens a route in the right column of a `SplitNavigationStack`.
/// Only ever called on the main actor, from the view it was handed to.
struct SplitRouteAction: @unchecked Sendable {
    let open: @MainActor (AnyHashable) -> Void
}

nonisolated private struct SplitRouteKey: EnvironmentKey {
    static let defaultValue: SplitRouteAction? = nil
}

extension EnvironmentValues {
    /// Set in the left column of a `SplitNavigationStack`, nil elsewhere.
    nonisolated var openSplitRoute: SplitRouteAction? {
        get { self[SplitRouteKey.self] }
        set { self[SplitRouteKey.self] = newValue }
    }
}

/// A link to a route: in the left column of a `SplitNavigationStack` it opens the route in the right column (a tap
/// on the page already open there shows it from its start), elsewhere it is a `NavigationLink(value:)`.
struct RouteLink<Value: Hashable, Label: View>: View {
    @Environment(\.openSplitRoute) private var openSplitRoute
    let value: Value
    @ViewBuilder var label: () -> Label

    init(value: Value, @ViewBuilder label: @escaping () -> Label) {
        self.value = value
        self.label = label
    }

    var body: some View {
        if let openSplitRoute {
            Button { openSplitRoute.open(AnyHashable(value)) } label: { label() }
        } else {
            NavigationLink(value: value, label: label)
        }
    }
}

/// The right column before anything is opened.
struct SplitPlaceholder: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AppBackground() }
    }
}

/// A list of pages (like the settings) that shows the opened page next to it on the iPad and the Mac, where links
/// in the list replace the right column. On the iPhone it's a plain `NavigationStack`.
struct SplitNavigationView<Sidebar: View, Placeholder: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.all
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar()
                    .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 460)
            } detail: {
                NavigationStack { placeholder() }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack { sidebar() }
        }
    }
}
