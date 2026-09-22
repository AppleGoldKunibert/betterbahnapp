import Foundation

public enum TransitError: Error, Sendable, Equatable, LocalizedError {
    case http(status: Int, body: String?)
    case rateLimited
    case decoding(String)
    case notFound(String)
    case invalidInput(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .http(let status, _): "Serverfehler (\(status))"
        case .rateLimited: "Zu viele Anfragen – bitte kurz warten."
        case .decoding(let detail): "Antwort konnte nicht gelesen werden: \(detail)"
        case .notFound(let what): "\(what) nicht gefunden."
        case .invalidInput(let detail): detail
        case .timeout: "Keine Antwort. Bitte versuch es später noch mal."
        }
    }
}

public struct HTTPClient: Sendable {
    /// Plain UA: bahn.de's bot protection rejects agents containing URLs.
    public static let userAgent = "BetterBahn/0.1 (iOS app)"
    /// Träwelling asks apps to identify themselves with a contact.
    public static let identifyingUserAgent = "BetterBahn/0.1 (iOS; +https://github.com/goldkunibert/betterbahnapp)"

    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    public func get<T: Decodable>(_ url: URL, as type: T.Type, headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request, as: type)
    }

    public func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await sendRaw(request)
        do {
            return try JSONDecoding.decoder.decode(T.self, from: data)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    public func sendRaw(_ request: URLRequest) async throws -> Data {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 429: throw TransitError.rateLimited
        default: throw TransitError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }
}

public enum JSONDecoding {
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleContainer()
            let string = try container.decode(String.self)
            guard let date = parseISODate(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
            }
            return date
        }
        return decoder
    }

    public static func parseISODate(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        return nil
    }

    public static func isoString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

private extension Decoder {
    func singleContainer() throws -> SingleValueDecodingContainer { try singleValueContainer() }
}
