import SwiftUI

/// A tab's navigation stack that becomes two columns on the iPad and the Mac (regular width): the tab's first page
/// stays on the left and everything it opens is pushed on the right. On the iPhone it's a plain `NavigationStack`.
///
/// Links on the left (`NavigationLink(value:)`) replace the right column's path instead of pushing on their own
/// column: that column's path always reads empty and hands what is set on to `path`.
struct SplitNavigationStack<Route: Hashable, Root: View, Destination: View, Placeholder: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var path: [Route]
    @ViewBuilder var root: () -> Root
    @ViewBuilder var destination: (Route) -> Destination
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        if sizeClass == .regular {
            // A split view rather than two stacks side by side, so the system lays out both columns like elsewhere.
            NavigationSplitView(columnVisibility: .constant(.all)) {
                NavigationStack(path: Binding(get: { [Route]() }, set: { opened in
                    if !opened.isEmpty { path = opened }
                })) {
                    root()
                        .navigationDestination(for: Route.self) { _ in EmptyView() }
                }
                .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 460)
                // The search stays visible: hiding it would leave nothing to open from.
                .toolbar(removing: .sidebarToggle)
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
