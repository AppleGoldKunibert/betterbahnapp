// Android stand-ins for the Kit parts that need Apple frameworks. build.sh links the Kit's own source
// folders next to this file, so the Kit compiles unchanged; Package.swift leaves out the Apple-only files.

// URLSession and XMLParser live in separate modules outside Apple platforms. Re-exported here so every Kit
// file sees them without its own import.
import Foundation
@_exported import FoundationNetworking
@_exported import FoundationXML

// App Attest (Support/WorkerAuth.swift) only exists on Apple devices. Android proves itself with Play Integrity
// instead (#467): the app gets the access token from `/auth/play` (`PlayIntegrity.kt`) and hands it over with the
// bridge method `setWorkerToken`. Without one requests go out without a token, like from the Simulator.
public final class WorkerAuth: @unchecked Sendable {
    public static let shared = WorkerAuth()
    public static let header = "X-BetterBahn-Token"

    private let lock = NSLock()
    private var token: (value: String, expires: Date)?

    /// The token from the app, or nil to forget it.
    public func set(_ value: String?, expires: Date) {
        lock.withLock { token = value.map { ($0, expires) } }
    }

    /// The token while it's valid for another minute.
    public func accessToken() -> String? {
        lock.withLock { token.flatMap { $0.expires.timeIntervalSinceNow > 60 ? $0.value : nil } }
    }

    /// The Worker refused it (new server secret): forgotten, so the app fetches a new one.
    func reject(_ value: String) {
        lock.withLock { if token?.value == value { token = nil } }
    }
}

extension HTTPClient {
    /// As on iOS, with the token the app handed over; a refused one is forgotten and the request fails.
    func sendRaw(_ request: URLRequest, auth: WorkerAuth?) async throws -> Data {
        guard let auth, let token = auth.accessToken() else { return try await sendRaw(request) }
        var request = request
        request.setValue(token, forHTTPHeaderField: WorkerAuth.header)
        do {
            return try await sendRaw(request)
        } catch TransitError.http(status: 401, let body) {
            auth.reject(token)
            throw TransitError.http(status: 401, body: body)
        }
    }

    func workerAuth(_ auth: WorkerAuth?) -> WorkerAuth? {
        auth ?? (session === URLSession.shared ? .shared : nil)
    }
}
