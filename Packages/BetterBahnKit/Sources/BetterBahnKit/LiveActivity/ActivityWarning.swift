import Foundation

extension TripActivityAttributes.ContentState {
    /// `warning` in the app's language. The app writes it in its own language, but our server
    /// (`Cloudflare/live-activity`, `warning()`) always writes the two `ConnectionIssue` titles in German.
    public var localizedWarning: String? { warning.map(Self.localizedWarning) }

    static func localizedWarning(_ warning: String) -> String {
        if warning.hasSuffix(" fällt aus") {
            return String(kit: "%@ fällt aus", String(warning.dropLast(" fällt aus".count)))
        }
        if warning.hasPrefix("Umstieg in "), warning.hasSuffix(" klappt nicht mehr") {
            let station = warning.dropFirst("Umstieg in ".count).dropLast(" klappt nicht mehr".count)
            return String(kit: "Umstieg in %@ klappt nicht mehr", String(station))
        }
        return warning
    }
}
