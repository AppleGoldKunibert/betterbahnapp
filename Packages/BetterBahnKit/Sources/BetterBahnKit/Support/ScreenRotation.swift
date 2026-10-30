import Foundation

/// Which phone screens may turn the app sideways (#487). A normal iPhone stays upright: its layouts aren't made for
/// landscape. Screens much wider than a phone's (the iPhone Duo, folded and unfolded) turn freely: limited to portrait,
/// iOS shows the app there in a narrow window with the status bar beside it and stretches it when the device turns.
public enum ScreenRotation {
    /// Long side over short side. Phones are about 2.17 (the oldest 16:9 ones 1.78), the Duo's screens 1.42 to 1.46.
    static let widestPhoneRatio = 1.6

    public static func turnsFreely(width: Double, height: Double) -> Bool {
        let short = min(width, height)
        guard short > 0 else { return false }
        return max(width, height) / short < widestPhoneRatio
    }
}
