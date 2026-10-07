import Compression
import Foundation

/// Encodes/decodes a `Journey` into a `betterbahn://share` deep link so it can be sent to another
/// user (e.g. via the share sheet) and reopened in their copy of the app.
///
/// Usually the encoded journey (the "payload") is stored by BetterBahn's Worker and only a short
/// `https://…/s/<id>` link is shared (`ShortShareLinkClient`); the long link is the offline fallback.
public enum JourneyShareLink {
    private static let scheme = "betterbahn"
    private static let host = "share"
    /// Where short links point (the `betterbahn` Worker, `Cloudflare/worker.mjs`). Must match the
    /// Associated Domains entitlement.
    public static let shortLinkBaseURL = URL(string: "https://betterbahn.betterbahn.workers.dev")!
    static let shortLinkPathPrefix = "/s/"

    public static func url(for journey: Journey) -> URL? {
        payload(for: journey).flatMap(url(forPayload:))
    }

    /// The journey as zlib-compressed JSON in base64url: the long link's `data`, and what the Worker stores.
    public static func payload(for journey: Journey) -> String? {
        guard let json = try? JSONEncoder().encode(journey),
              let compressed = try? (json as NSData).compressed(using: .zlib) as Data? else { return nil }
        return base64URLEncode(compressed)
    }

    public static func url(forPayload payload: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "data", value: payload)]
        return components.url
    }

    /// Returns the shared `Journey`, or `nil` if `url` isn't a recognized (or valid) share link.
    /// Short links aren't resolved here, see `shortLinkID(from:)`.
    public static func journey(from url: URL) -> Journey? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == host,
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value else { return nil }
        return journey(fromPayload: encoded)
    }

    /// Decodes a payload, from a long link or the Worker, within the size limits below.
    public static func journey(fromPayload encoded: String) -> Journey? {
        guard encoded.count <= maxEncodedLength,
              let compressed = base64URLDecode(encoded),
              let json = inflate(compressed) else { return nil }
        return try? JSONDecoder().decode(Journey.self, from: json)
    }

    /// The ID of a short link: `https://…/s/<id>` (Universal Link) or `betterbahn://share?id=<id>`
    /// (the fallback page's button). Nil for anything else.
    public static func shortLinkID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id: String?
        if components.scheme == scheme, components.host == host {
            id = components.queryItems?.first(where: { $0.name == "id" })?.value
        } else if components.scheme == "https", components.host == shortLinkBaseURL.host(),
                  components.path.hasPrefix(shortLinkPathPrefix) {
            id = String(components.path.dropFirst(shortLinkPathPrefix.count))
        } else {
            id = nil
        }
        guard let id, isValidShortLinkID(id) else { return nil }
        return id
    }

    static func isValidShortLinkID(_ id: String) -> Bool {
        id.count == 8 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Any website can open a share link, so its size is capped: a small payload that inflates
    /// to gigabytes must not take the app down. Real journeys stay far below both.
    static let maxEncodedLength = 64 * 1024
    static let maxJSONSize = 1024 * 1024

    /// Raw-deflate data (what `NSData.compressed(using: .zlib)` writes), or nil if it would inflate
    /// to more than `maxJSONSize`.
    static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = maxJSONSize + 1
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0, size <= maxJSONSize else { return nil }
        return output.prefix(size)
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
