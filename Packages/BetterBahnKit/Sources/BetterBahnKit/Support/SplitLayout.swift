import Foundation

/// The two-column layout on the iPad and the Mac: a tab's first page on the left, what it opens on the right.
public enum SplitLayout {
    /// The left column's width for a window `width` points wide: wide enough for the search form, the rest goes to
    /// the details.
    public static func sidebarWidth(for width: Double) -> Double {
        min(420, max(320, width * 0.4))
    }
}
