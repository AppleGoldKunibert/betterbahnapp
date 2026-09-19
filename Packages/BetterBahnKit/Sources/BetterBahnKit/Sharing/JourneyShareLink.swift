import Compression
import Foundation

/// Encodes/decodes a `Journey` into a `betterbahn://share` deep link so it can be sent to another
/// user (e.g. via the share sheet) and reopened in their copy of the app.
public enum JourneyShareLink {
    private static let scheme = "betterbahn"
    private static let host = "share"

    public static func url(for journey: Journey) -> URL? {
        guard let json = try? JSONEncoder().encode(journey),
              let compressed = try? (json as NSData).compressed(using: .zlib) as Data? else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "data", value: base64URLEncode(compressed))]
        return components.url
    }

    /// Returns the shared `Journey`, or `nil` if `url` isn't a recognized (or valid) share link.
    public static func journey(from url: URL) -> Journey? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == host,
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value,
              let compressed = base64URLDecode(encoded),
              let json = try? (compressed as NSData).decompressed(using: .zlib) as Data? else { return nil }
        return try? JSONDecoder().decode(Journey.self, from: json)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

extension Journey {
    /// A deep link that reopens this journey in another user's copy of the app.
    public var shareURL: URL? { JourneyShareLink.url(for: self) }
}
