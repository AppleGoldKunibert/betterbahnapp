import Foundation

/// bahn.de's journey IDs by run (#411). A run's ID never changes, so finding it (a departure board request) should
/// happen once: they are kept on the device for 12 hours, also over a restart of the app, which used to ask a board
/// per train again on every launch (ten boards within a second got our server refused). A run bahn.de doesn't list
/// is remembered for a few minutes, so it isn't looked for on every refresh.
actor JourneyIdStore {
    struct Entry: Codable, Sendable {
        var id: String
        var date: Date
    }

    static let maxAge: TimeInterval = 12 * 3600
    static let missingAge: TimeInterval = 10 * 60

    /// The app's, in its caches folder.
    static let shared = JourneyIdStore(file: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "BetterBahn/bahnde-journey-ids.json"))

    private let file: URL?
    /// Read from `file` on first use.
    private var entries: [String: Entry]?
    private var missing: [String: (date: Date, error: TransitError)] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    init(file: URL?) {
        self.file = file
    }

    /// The ID for `key`, kept or found with `find`. Asking for the same key at the same time shares one `find`.
    func id(for key: String, now: Date = .now, find: @escaping @Sendable () async throws -> String) async throws -> String {
        if let id = cached(key, now: now) { return id }
        if let miss = missing[key], now.timeIntervalSince(miss.date) < Self.missingAge { throw miss.error }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await find() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let id = try await task.value
            store(id, for: key, now: now)
            return id
        } catch let error as TransitError where error.isNotFound {
            missing = missing.filter { now.timeIntervalSince($0.value.date) < Self.missingAge }
            missing[key] = (now, error)
            throw error
        }
    }

    /// The kept ID for `key`, without looking for it.
    func cached(_ key: String, now: Date = .now) -> String? {
        guard let entry = load(now: now)[key], now.timeIntervalSince(entry.date) < Self.maxAge else { return nil }
        return entry.id
    }

    private func store(_ id: String, for key: String, now: Date) {
        var kept = load(now: now).filter { now.timeIntervalSince($0.value.date) < Self.maxAge }
        kept[key] = Entry(id: id, date: now)
        entries = kept
        guard let file, let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func load(now: Date) -> [String: Entry] {
        if let entries { return entries }
        let stored = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        let kept = stored.filter { now.timeIntervalSince($0.value.date) < Self.maxAge }
        entries = kept
        return kept
    }
}
