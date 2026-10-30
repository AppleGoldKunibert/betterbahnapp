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
}
