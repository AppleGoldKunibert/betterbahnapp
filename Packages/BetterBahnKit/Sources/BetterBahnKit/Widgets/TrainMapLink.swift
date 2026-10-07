import Foundation

/// `betterbahn://map?journey=…&leg=…` – opened when a live widget is tapped, so the app shows the
/// live map of that saved journey's train (the leg at `legIndex` in `Journey.legs`).
public enum TrainMapLink {
    static let scheme = "betterbahn"
    static let host = "map"

    public static func url(journeyID: String, legIndex: Int) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "journey", value: journeyID),
                                 URLQueryItem(name: "leg", value: String(legIndex))]
        return components.url!
    }

    /// The journey ID and leg index from a link made by `url(journeyID:legIndex:)`, nil for any other URL.
    public static func target(from url: URL) -> (journeyID: String, legIndex: Int)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == host,
              let id = components.queryItems?.first(where: { $0.name == "journey" })?.value, !id.isEmpty,
              let leg = components.queryItems?.first(where: { $0.name == "leg" })?.value.flatMap(Int.init),
              leg >= 0 else { return nil }
        return (id, leg)
    }
}
