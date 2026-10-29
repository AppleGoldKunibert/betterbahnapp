import Foundation

/// Syncing a list item by item as records (saved journeys through CloudKit, #427): what changed locally and which side
/// wins when both changed an item.
public enum RecordSync {
    /// The items to upload and the ones to delete after a local edit from `old` to `new`, by `id.description`.
    public struct Changes: Equatable, Sendable {
        public var saved: [String]
        public var removed: [String]

        public init(saved: [String], removed: [String]) {
            self.saved = saved
            self.removed = removed
        }

        public var isEmpty: Bool { saved.isEmpty && removed.isEmpty }
    }

    public static func changes<Element: Identifiable & Equatable>(from old: [Element], to new: [Element]) -> Changes
    where Element.ID: CustomStringConvertible {
        let oldByID = Dictionary(old.map { ($0.id.description, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id.description))
        var saved: [String] = []
        var seen = Set<String>()
        for item in new where oldByID[item.id.description] != item && seen.insert(item.id.description).inserted {
            saved.append(item.id.description)
        }
        let removed = old.map(\.id.description).filter { !newIDs.contains($0) }
        return Changes(saved: saved, removed: Array(Set(removed)).sorted())
    }

    /// Whether an item fetched from the server replaces the local one: unless this device changed it later. On a tie
    /// the server wins, like `SyncedList`; an item without a date loses against one with a date.
    public static func remoteWins(local: Date?, remote: Date?) -> Bool {
        guard let local else { return true }
        guard let remote else { return false }
        return remote >= local
    }
}
