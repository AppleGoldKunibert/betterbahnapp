import Foundation

/// Our own server for bahn.de's web API (`Server/bahnde-proxy`, #342). bahn.de's bot protection refuses
/// every request whose TLS handshake isn't a browser's, which Cloudflare Workers can't change; the server
/// asks with a browser's handshake. It mirrors the Worker's `/web/api/…` paths and takes the same App Attest
/// token. `BahnDeClient` asks only this server; while it is down or refused it is left alone for a while
/// (`gate`) and the app says the live data isn't available.
public struct BahnDeProxy: Sendable {
    /// Where the server runs: a small game-server host, reached over HTTPS through Tailscale Funnel
    /// (`panel_boot.py`, see Server/bahnde-proxy/README.md). bahn.de refuses Oracle Cloud's addresses.
    /// nil sends bahn.de requests to the Worker's address itself, which bahn.de refuses since October 2026.
    public static let baseURL: URL? = URL(string: "https://bahnde-proxy.tail6eed6b.ts.net")

    /// The app's proxy, nil while there is no server.
    public static let shared: BahnDeProxy? = baseURL.map { BahnDeProxy(baseURL: $0) }

    let baseURL: URL
    /// Leaves the server alone for a while after it failed: blocked by bahn.de, down or paused.
    let gate: BahnDeGate
    /// How long to wait before trying a hiccup again, times the attempt (`BahnDeClient.isHiccup`).
    let retryDelay: Duration

    /// Tries a request this often when it hits a hiccup, before every request pauses.
    static let attempts = 3

    public init(baseURL: URL, gate: BahnDeGate = BahnDeGate(), retryDelay: Duration = .milliseconds(500)) {
        self.baseURL = baseURL
        self.gate = gate
        self.retryDelay = retryDelay
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
