import Foundation

/// Our own server for bahn.de's web API (`Server/bahnde-proxy`, #342). bahn.de's bot protection refuses
/// every request whose TLS handshake isn't a browser's, which Cloudflare Workers can't change; the server
/// asks with a browser's handshake. It mirrors the Worker's `/web/api/…` paths and takes the same App Attest
/// token, so `BahnDeClient` asks it first and falls back to the Worker (and the phone's hidden browser)
/// while it is down or refused, see `gate`.
public struct BahnDeProxy: Sendable {
    /// Where the server runs; nil until it is deployed, then the app asks only the Worker.
    public static let baseURL: URL? = nil

    /// The app's proxy, nil while there is no server.
    public static let shared: BahnDeProxy? = baseURL.map { BahnDeProxy(baseURL: $0) }

    let baseURL: URL
    /// Leaves the server alone for a while after it failed: blocked by bahn.de, down or paused.
    let gate: BahnDeGate

    public init(baseURL: URL, gate: BahnDeGate = BahnDeGate()) {
        self.baseURL = baseURL
        self.gate = gate
    }

    /// The server's address for a request to the Worker (same path and query), nil for anything else.
    func url(for workerURL: URL) -> URL? {
        guard workerURL.host() == BahnDeClient.baseURL.host(), workerURL.path().hasPrefix("/web/api/"),
              var components = URLComponents(url: workerURL, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = target.scheme
        components.host = target.host
        components.port = target.port
        return components.url
    }
}
