import Foundation

/// Mirrors favourites, saved journeys and settings into iCloud key-value storage, so a new or second
/// device picks them up. The last write wins per key. Träwelling and Timetables logins travel through
/// iCloud Keychain instead (see the Keychain stores in BetterBahnKit). Without iCloud everything
/// silently stays local.
final class CloudSync {
    static let shared = CloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private static let maxValueBytes = 500_000 // iCloud allows 1 MB per app in total

    /// True while values from iCloud are applied, so they aren't pushed straight back.
    private(set) var isApplyingRemote = false

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // stable bytes, so unchanged data isn't re-uploaded
        return encoder
    }()

    /// Starts listening; `onChange` gets the keys another device changed.
    func start(onChange: @escaping @MainActor (Set<String>) -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] note in
            let keys = Set(note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? [])
            MainActor.assumeIsolated { self?.applyRemote { onChange(keys) } }
        }
        store.synchronize()
    }

    func applyRemote(_ body: () -> Void) {
        isApplyingRemote = true
        body()
        isApplyingRemote = false
    }

    func hasValue(key: String) -> Bool { store.object(forKey: key) != nil }

    func value<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func push<T: Encodable>(_ value: T, key: String) {
        guard !isApplyingRemote, let data = try? encoder.encode(value),
              data.count < Self.maxValueBytes, store.data(forKey: key) != data else { return }
        store.set(data, forKey: key)
    }

    /// Bool/Int values (settings).
    func pushPlain(_ value: Any, key: String) {
        guard !isApplyingRemote, (store.object(forKey: key) as? NSObject) != (value as? NSObject) else { return }
        store.set(value, forKey: key)
    }

    func plain(key: String) -> Any? { store.object(forKey: key) }
}
