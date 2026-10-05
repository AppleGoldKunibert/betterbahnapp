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
    /// Where service operators can reach BetterBahn (`Cloudflare/worker.mjs`, `/support`).
    public static let contactURL = "https://betterbahn.betterbahn.workers.dev/support"
    /// Sent with every request: Transitous, OpenRailwayMap and Träwelling ask apps to name themselves,
    /// their version and a contact. Only the bahn.de proxy sends a browser agent instead (`BahnDeClient`).
    public static let identifyingUserAgent = userAgent(version: appVersion)

    /// The app's version (`MARKETING_VERSION`); extensions carry the same one.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static func userAgent(version: String) -> String {
        "BetterBahn/\(version) (iOS; +\(contactURL))"
    }

    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    /// `auth` adds BetterBahn's App Attest token, for requests to its own Workers.
    public func get<T: Decodable>(_ url: URL, as type: T.Type, headers: [String: String] = [:],
                                  auth: WorkerAuth? = nil) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(Self.identifyingUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request, as: type, auth: auth)
    }

    public func send<T: Decodable>(_ request: URLRequest, as type: T.Type, auth: WorkerAuth? = nil) async throws -> T {
        let data = try await sendRaw(request, auth: auth)
        do {
            return try JSONDecoding.decoder.decode(T.self, from: data)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    public func sendRaw(_ request: URLRequest) async throws -> Data {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.identifyingUserAgent, forHTTPHeaderField: "User-Agent")
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
