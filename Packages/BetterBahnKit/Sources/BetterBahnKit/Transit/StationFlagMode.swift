import Foundation

/// When the station search shows a country flag before a station's name (#349).
public enum StationFlagMode: String, CaseIterable, Codable, Sendable {
    case off
    /// Only for stations outside the user's own country.
    case foreignOnly
    case always

    /// The flag to show before `station`'s name, given the user's own country (ISO code); nil for none.
    public func flag(for station: Station, home: String?) -> String? {
        guard self != .off, let code = station.countryCode, let flag = station.flag else { return nil }
        if self == .foreignOnly, code == home?.uppercased() { return nil }
        return flag
    }
}
