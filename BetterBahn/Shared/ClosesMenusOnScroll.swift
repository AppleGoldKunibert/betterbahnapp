import SwiftUI
import UIKit

extension View {
    /// Closes an open `Menu` or menu `Picker` as soon as this scroll view is scrolled. They stay open while
    /// the content scrolls underneath and slide along with their button, away from the finger.
    func closesMenusOnScroll() -> some View {
        modifier(ClosesMenusOnScroll())
    }

    /// For a menu with a glass label inside a `closesMenusOnScroll()` scroll view: closing it mid-scroll leaves
    /// the label where the menu was, so it's rebuilt in its place.
    func resetsWhenMenusCloseOnScroll() -> some View {
        modifier(ResetsWhenMenusClose())
    }
}

nonisolated private struct MenuClosingScrollsKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Counts the scrolls that closed menus, see `closesMenusOnScroll()`.
    nonisolated var menuClosingScrolls: Int {
        get { self[MenuClosingScrollsKey.self] }
        set { self[MenuClosingScrollsKey.self] = newValue }
    }
}

private struct ClosesMenusOnScroll: ViewModifier {
    @State private var closings = 0

    func body(content: Content) -> some View {
        content
            .environment(\.menuClosingScrolls, closings)
            .onScrollPhaseChange { _, phase in
                guard phase == .interacting else { return }
                closeOpenMenus()
                closings += 1
            }
    }
}

private struct ResetsWhenMenusClose: ViewModifier {
    @Environment(\.menuClosingScrolls) private var closings

    func body(content: Content) -> some View {
        content.id(closings)
    }
}

/// SwiftUI has no way to close a menu, but each one is shown by a `UIContextMenuInteraction`.
private func closeOpenMenus() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        for window in scene.windows { closeMenus(in: window) }
    }
}

private func closeMenus(in view: UIView) {
    for case let interaction as UIContextMenuInteraction in view.interactions { interaction.dismissMenu() }
    for subview in view.subviews { closeMenus(in: subview) }
}
