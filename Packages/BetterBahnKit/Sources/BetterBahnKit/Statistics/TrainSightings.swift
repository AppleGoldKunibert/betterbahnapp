import Foundation

/// Trains the app has shown, reported to the `betterbahn-stats` Worker (`Cloudflare/stats`), which then
/// follows each run to its terminus and keeps its delays, platforms, cancellations and Wagenreihung for
/// statistics (#169). Only bahn.de's journey IDs of regional and long-distance trains go out, collected
/// where the app looks a train up on bahn.de anyway (`BahnDeClient`); no user ID, no location.
///
/// Off until the app turns it on (`setEnabled`, the "Zugdaten für Statistik teilen" setting). Reports
/// are batched: the first new train starts a short wait, then everything collected goes out at once.
/// Best effort: a failed report is dropped, the trains count again when they're seen again.
public actor TrainSightings {
    public static let shared = TrainSightings()
    public static let baseURL = URL(string: "https://betterbahn-stats.betterbahn.workers.dev")!
    /// The Worker takes at most this many IDs per request.
    static let maxPerRequest = 100
    /// IDs remembered as sent, so a board refreshed every minute doesn't report its trains again.
    static let sentMemory = 2_000

    public typealias Sender = @Sendable ([String]) async throws -> Void

    private let sender: Sender
    private let delay: Duration
    private var isEnabled = false
    private var pending: [String] = []
    private var sent: [String] = []
    private var sentSet: Set<String> = []
    private var flushTask: Task<Void, Never>?

    /// `sender` defaults to posting to the Worker with the app's App Attest token.
    public init(delay: Duration = .seconds(20), sender: Sender? = nil) {
        self.delay = delay
        self.sender = sender ?? { ids in try await Self.post(ids) }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            pending.removeAll()
            flushTask?.cancel()
            flushTask = nil
        }
    }

    /// Notes bahn.de journey IDs of trains that were shown; reported after a short wait.
    public func record(_ journeyIds: [String]) {
        guard isEnabled else { return }
        for id in journeyIds where !id.isEmpty && !sentSet.contains(id) && !pending.contains(id) {
            pending.append(id)
        }
        guard !pending.isEmpty, flushTask == nil else { return }
        flushTask = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    /// Sends everything collected now (also used when the app goes to the background).
    public func flush() async {
        flushTask = nil
        guard isEnabled, !pending.isEmpty else { return }
        let ids = pending
        pending.removeAll()
        remember(ids)
        for start in stride(from: 0, to: ids.count, by: Self.maxPerRequest) {
            try? await sender(Array(ids[start..<min(start + Self.maxPerRequest, ids.count)]))
        }
    }

    private func remember(_ ids: [String]) {
        sent += ids
        sentSet.formUnion(ids)
        if sent.count > Self.sentMemory {
            let dropped = sent.prefix(sent.count - Self.sentMemory)
            sentSet.subtract(dropped)
            sent.removeFirst(dropped.count)
        }
    }

    static func post(_ ids: [String], http: HTTPClient = HTTPClient(timeout: 15)) async throws {
        var request = URLRequest(url: baseURL.appending(path: "sightings"), timeoutInterval: http.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["journeyIds": ids])
        _ = try await http.sendRaw(request, auth: http.workerAuth(nil))
    }

    /// bahn.de products that aren't reported: S-Bahn and everything that isn't a train.
    static let excludedProducts: Set<String> = ["SBAHN", "UBAHN", "TRAM", "BUS", "SCHIFF", "ANRUFPFLICHTIG"]
}

extension BahnDeClient {
    /// Reports the trains of these bahn.de board entries as seen (regional and long-distance only).
    /// Only on the app's real session, so tests never report anything.
    func reportSightings(_ entries: [Board.Entry]) {
        guard usesSharedCaches else { return }
        let ids = entries
            .filter { !TrainSightings.excludedProducts.contains($0.verkehrmittel?.produktGattung ?? "") }
            .map(\.journeyId)
        guard !ids.isEmpty else { return }
        Task { await TrainSightings.shared.record(ids) }
    }
}
