import Foundation

/// Which phone windows get the iPad's two columns, list on the left and details on the right (#464): the iPhone Duo
/// unfolded, upright and sideways. iOS calls a phone narrow whenever it is upright, however wide its screen is; folded
/// the Duo stays one column like an iPhone.
public enum PhoneColumns {
    /// Points on the window's short side. iPhones have up to 440, the Duo about 466 folded and 669 unfolded.
    static let narrowestSide = 600.0

    public static func fit(width: Double, height: Double) -> Bool {
        min(width, height) >= narrowestSide
    }

    /// What a phone window is told about its width.
    public enum Width: Equatable, Sendable {
        /// Wide: two columns.
        case regular
        /// Narrow: one column, also where iOS would call the window wide.
        case compact
        /// Whatever iOS says.
        case system
    }

    /// Two columns where they fit; one where the window is narrower than two columns need, as next to another app on
    /// the unfolded Duo, which iOS calls wide when the device is sideways (#579). Otherwise iOS decides.
    public static func width(width: Double, height: Double) -> Width {
        if fit(width: width, height: height) { return .regular }
        return width < narrowestSide ? .compact : .system
    }
}
