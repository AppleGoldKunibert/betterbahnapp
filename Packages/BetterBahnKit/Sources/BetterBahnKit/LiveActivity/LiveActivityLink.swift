import Foundation

/// `betterbahn://journey?id=…` – opened when the Live Activity is tapped, so the app shows that
/// saved journey instead of whatever screen was open last.
public enum LiveActivityLink {
    static let scheme = "betterbahn"
    static let host = "journey"

    public static func url(journeyID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "id", value: journeyID)]
        return components.url!
    }

    /// The journey ID from a link made by `url(journeyID:)`, nil for any other URL.
    public static func journeyID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == host,
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { return nil }
        return id
    }
}
