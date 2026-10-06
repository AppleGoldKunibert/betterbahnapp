import BetterBahnKit
import Foundation

/// Mirrors settings, favourite stations, recent searches and saved journeys to the iCloud
/// key-value store so they show up on the user's other devices. The Träwelling login syncs
/// separately through iCloud Keychain (`TokenStore`).
///
/// Values are stored as compressed JSON under `cloud.<key>`. The store holds 1 MB in total, so
/// a value that doesn't fit is simply not synced and stays on this device.
nonisolated enum CloudSync {
    private static var store: NSUbiquitousKeyValueStore { .default }
    private static let maxValueSize = 900_000

    static func upload<T: Encodable>(_ value: T, key: String) {
        let encoder = JSONEncoder()
        // Stable output, so an unchanged value isn't written (and synced) again.
        encoder.outputFormatting = .sortedKeys
        guard let json = try? encoder.encode(value),
              let data = try? (json as NSData).compressed(using: .lzfse) as Data,
              data.count <= maxValueSize else { return }
        let cloudKey = "cloud." + key
        guard store.data(forKey: cloudKey) != data else { return }
        store.set(data, forKey: cloudKey)
    }

    private static let uploader = DispatchQueue(label: "de.goldkunibert.BetterBahn.cloudsync", qos: .utility)

    /// Like `upload`, but encodes and compresses on a background queue, in the order of the calls.
    static func uploadInBackground<T: Encodable & Sendable>(_ value: T, key: String) {
        uploader.async { upload(value, key: key) }
    }

    static func value<T: Decodable>(key: String) -> T? {
        guard let data = store.data(forKey: "cloud." + key),
              let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: json)
    }

    /// Calls `handler` on the main actor with the changed keys (without the `cloud.` prefix)
    /// whenever iCloud delivers values from another device.
    static func observe(_ handler: @escaping @MainActor ([String]) -> Void) -> NSObjectProtocol {
        let token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            // A quota violation brings nothing new to apply.
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            guard reason != NSUbiquitousKeyValueStoreQuotaViolationChange else { return }
            let keys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? [])
                .filter { $0.hasPrefix("cloud.") }
                .map { String($0.dropFirst("cloud.".count)) }
            guard !keys.isEmpty else { return }
            MainActor.assumeIsolated { handler(keys) }
        }
        store.synchronize()
        return token
    }
}

/// Syncs one list through iCloud item by item, so a conflict never loses an item and removals
/// carry over (see `SyncedList`). When each item last changed is kept next to the list.
final class CloudList<Element: Codable & Sendable & Identifiable & Equatable> where Element.ID: CustomStringConvertible {
    let key: String
    private var changedAt: [String: Date]
    private var isApplyingCloud = false

    init(key: String) {
        self.key = key
        changedAt = Storage.load(key: "cloudSync-" + key) ?? [:]
    }

    /// Call from the list's `didSet`: dates what the user changed and uploads the list.
    func localChange(from old: [Element], to new: [Element]) {
        var list = SyncedList(items: new, changedAt: changedAt)
        // Items taken over from iCloud keep the dates they came with.
        if !isApplyingCloud { list.record(from: old, to: new) }
        save(list)
    }

    /// Merges iCloud's copy with `local` and hands the result to `apply` if it differs.
    func receive(local: [Element], apply: ([Element]) -> Void) {
        let localList = SyncedList(items: local, changedAt: changedAt)
        guard let cloud: SyncedList<Element> = CloudSync.value(key: key) else {
            if !local.isEmpty || !changedAt.isEmpty { save(localList) }
            return
        }
        let merged = localList.merged(withCloud: cloud)
        if merged.items != local {
            changedAt = merged.changedAt
            isApplyingCloud = true
            apply(merged.items) // saves and uploads through `localChange`
            isApplyingCloud = false
        } else {
            save(merged)
        }
    }

    private func save(_ list: SyncedList<Element>) {
        if list.changedAt != changedAt {
            changedAt = list.changedAt
            Storage.save(changedAt, key: "cloudSync-" + key)
        }
        CloudSync.uploadInBackground(list, key: key)
    }
}
