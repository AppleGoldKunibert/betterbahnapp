import Foundation

/// `betterbahn://board?station=…` – opened when the departure board widget is tapped, so the app shows
/// that station's board; with `to=…` (the widget's commuter route) the connection search from the
/// station to that destination instead. The stations travel in the link itself (JSON, base64url), so
/// the app needs no lookup: a station removed from the favourites still opens.
public enum BoardWidgetLink {
    static let scheme = "betterbahn"
    static let host = "board"

    public enum Target: Sendable, Hashable {
        /// The departure board of `station`.
        case board(Station)
        /// The connection search `from` → `to`.
        case route(from: Station, to: Station)
    }

    public static func url(station: Station, destination: Station? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [URLQueryItem(name: "station", value: encode(station))]
        if let destination {
            items.append(URLQueryItem(name: "to", value: encode(destination)))
        }
        components.queryItems = items
        return components.url!
    }

    /// What a link made by `url(station:destination:)` opens, nil for any other URL.
    public static func target(from url: URL) -> Target? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == host,
              let station = components.queryItems?.first(where: { $0.name == "station" })?.value.flatMap(decode) else { return nil }
        if let to = components.queryItems?.first(where: { $0.name == "to" })?.value.flatMap(decode) {
            return .route(from: station, to: to)
        }
        return .board(station)
    }

    /// A station as a URL-safe string (also the widget's entity ID for it, which AppIntents only ever
    /// hands back as that string).
    public static func encode(_ station: Station) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(station)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Station? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(Station.self, from: data)
    }
}
