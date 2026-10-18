import SwiftUI
import UIKit

extension View {
    /// Closes an open `Menu` or menu `Picker` as soon as this scroll view is scrolled. They stay open while
    /// the content scrolls underneath and slide along with their button, away from the finger.
    func closesMenusOnScroll() -> some View {
        onScrollPhaseChange { _, phase in
            if phase == .interacting { closeOpenMenus() }
        }
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
