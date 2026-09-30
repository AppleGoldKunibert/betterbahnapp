import Foundation

/// Mirrors settings, favourite stations, recent searches and saved journeys to the iCloud
/// key-value store so they show up on the user's other devices. The Träwelling login syncs
/// separately through iCloud Keychain (`TokenStore`).
///
/// Values are stored as compressed JSON under `cloud.<key>`. The store holds 1 MB in total, so
/// a value that doesn't fit is simply not synced and stays on this device.
nonisolated enum CloudSync {
    enum Change {
        /// First download on this device or a different iCloud account: merge with what's local.
        case initial
        /// Another device changed the value: take it over.
        case update
    }

    private static var store: NSUbiquitousKeyValueStore { .default }
    private static let maxValueSize = 900_000

    static func upload<T: Encodable>(_ value: T, key: String) {
        guard let json = try? JSONEncoder().encode(value),
              let data = try? (json as NSData).compressed(using: .lzfse) as Data,
              data.count <= maxValueSize else { return }
        let cloudKey = "cloud." + key
        guard store.data(forKey: cloudKey) != data else { return }
        store.set(data, forKey: cloudKey)
    }

    static func value<T: Decodable>(key: String) -> T? {
        guard let data = store.data(forKey: "cloud." + key),
              let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: json)
    }

    static func hasValue(key: String) -> Bool {
        store.data(forKey: "cloud." + key) != nil
    }

    /// Calls `handler` on the main actor with the changed keys (without the `cloud.` prefix)
    /// whenever iCloud delivers values from another device.
    static func observe(_ handler: @escaping @MainActor ([String], Change) -> Void) -> NSObjectProtocol {
        let token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? [])
                .filter { $0.hasPrefix("cloud.") }
                .map { String($0.dropFirst("cloud.".count)) }
            let change: Change? = switch reason {
            case NSUbiquitousKeyValueStoreServerChange: .update
            case NSUbiquitousKeyValueStoreInitialSyncChange, NSUbiquitousKeyValueStoreAccountChange: .initial
            default: nil // quota violation: nothing new to apply
            }
            guard let change, !keys.isEmpty else { return }
            MainActor.assumeIsolated { handler(keys, change) }
        }
        store.synchronize()
        return token
    }

    /// For a first sync: the cloud's items followed by local ones it doesn't have yet, so nothing
    /// either device had gets lost.
    static func merged<T: Identifiable>(cloud: [T], local: [T]) -> [T] {
        let cloudIDs = Set(cloud.map(\.id))
        return cloud + local.filter { !cloudIDs.contains($0.id) }
    }
}
