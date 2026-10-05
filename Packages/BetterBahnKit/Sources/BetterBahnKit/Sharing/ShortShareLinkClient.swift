import Foundation

public enum ShortShareLinkError: Error, Sendable, Equatable, LocalizedError {
    /// The link is unknown or older than the Worker keeps journeys (30 days).
    case expired
    /// The Worker's answer isn't a journey.
    case invalid

    public var errorDescription: String? {
        switch self {
        case .expired: "Dieser Link ist abgelaufen. Lass dir die Reise noch einmal schicken."
        case .invalid: "Dieser Link funktioniert leider nicht."
        }
    }
}

/// Short share links (`https://…/s/<id>`): stores a journey's `JourneyShareLink` payload in the
/// `betterbahn` Worker (`Cloudflare/worker.mjs`, `/share`) and fetches it back for a link.
public struct ShortShareLinkClient: Sendable {
    let http: HTTPClient
    let auth: WorkerAuth?
    let baseURL: URL

    /// `auth` defaults to `WorkerAuth.shared` on the app's real session and none on others (tests).
    public init(http: HTTPClient = HTTPClient(timeout: 10), auth: WorkerAuth? = nil,
                baseURL: URL = JourneyShareLink.shortLinkBaseURL) {
        self.http = http
        self.auth = http.workerAuth(auth)
        self.baseURL = baseURL
    }

    /// What to share for `journey`: a short link, or the long `betterbahn://share` link when the
    /// Worker can't be reached or refuses (offline, no App Attest, rate limit).
    public func shareURL(for journey: Journey) async -> URL? {
        guard let payload = JourneyShareLink.payload(for: journey) else { return nil }
        return await shareURL(forPayload: payload)
    }

    public func shareURL(forPayload payload: String) async -> URL? {
        if let url = try? await shortURL(forPayload: payload) { return url }
        return JourneyShareLink.url(forPayload: payload)
    }

    /// Stores `payload` and returns its short link.
    public func shortURL(forPayload payload: String) async throws -> URL {
        var request = URLRequest(url: baseURL.appending(path: "share"), timeoutInterval: http.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["data": payload])
        let response = try await http.send(request, as: CreatedResponse.self, auth: auth)
        guard JourneyShareLink.isValidShortLinkID(response.id) else { throw ShortShareLinkError.invalid }
        return baseURL.appending(path: "s/\(response.id)")
    }

    /// The journey behind a short link's `id` (see `JourneyShareLink.shortLinkID(from:)`).
    public func journey(id: String) async throws -> Journey {
        guard JourneyShareLink.isValidShortLinkID(id) else { throw ShortShareLinkError.invalid }
        let response: PayloadResponse
        do {
            response = try await http.get(baseURL.appending(path: "share/\(id)"), as: PayloadResponse.self)
        } catch TransitError.http(status: 404, body: _) {
            throw ShortShareLinkError.expired
        } catch TransitError.decoding {
            throw ShortShareLinkError.invalid
        }
        guard let journey = JourneyShareLink.journey(fromPayload: response.data) else { throw ShortShareLinkError.invalid }
        return journey
    }

    struct CreatedResponse: Decodable { var id: String }
    struct PayloadResponse: Decodable { var data: String }
}
