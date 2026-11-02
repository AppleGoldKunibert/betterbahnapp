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
    /// Whether the touch that's scrolling came while the page was at rest; only read in the scroll callback.
    @State private var startedAtRest = true

    func body(content: Content) -> some View {
        content
            .environment(\.menuClosingScrolls, closings)
            .onScrollPhaseChange { old, phase in
                // A finger first touches (tracking), then drags (interacting).
                if phase == .tracking { startedAtRest = old == .idle }
                // Only when a scroll starts from rest: a menu can only be opened then. Grabbing the page again
                // while it still glides (a quick second swipe, changing direction) used to walk all views and
                // rebuild the share button each time, which made the page stutter.
                guard phase == .interacting, old == .idle || (old == .tracking && startedAtRest) else { return }
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
/// Only the visible windows of the scenes on screen, and only views that are shown: the ones behind the other
/// tabs and hidden ones can't have an open menu.
private func closeOpenMenus() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
    where scene.activationState == .foregroundActive {
        for window in scene.windows where !window.isHidden { closeMenus(in: window) }
    }
}

private func closeMenus(in view: UIView) {
    guard !view.isHidden, view.alpha > 0 else { return }
    for case let interaction as UIContextMenuInteraction in view.interactions { interaction.dismissMenu() }
    for subview in view.subviews { closeMenus(in: subview) }
}
