import Foundation

/// A list kept in sync between devices (via iCloud) that never loses an item to a conflict:
/// every item remembers when it was last added, changed or removed, and when two copies are
/// merged, the newer change wins item by item. Removed items stay behind as a date only, so a
/// removal isn't undone by a device that still has the item.
public struct SyncedList<Element: Codable & Sendable & Identifiable & Equatable>: Codable, Sendable, Equatable
where Element.ID: CustomStringConvertible {
    public var items: [Element]
    /// When each item was last added, changed or removed, keyed by `id.description`. An id that
    /// is here but not in `items` was removed. Items from before syncing existed have no date.
    public var changedAt: [String: Date]

    /// Removals older than this are forgotten, so the list doesn't grow forever.
    public static var removalMemory: TimeInterval { 180 * 24 * 3600 }

    public init(items: [Element], changedAt: [String: Date] = [:]) {
        self.items = items
        self.changedAt = changedAt
    }

    /// Takes over a local edit from `old` to `new`, dating every item that was added, changed
    /// or removed with `date`.
    public mutating func record(from old: [Element], to new: [Element], at date: Date = .now) {
        let oldByID = Dictionary(old.map { ($0.id.description, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id.description))
        for item in new where oldByID[item.id.description] != item {
            changedAt[item.id.description] = date
        }
        for id in oldByID.keys where !newIDs.contains(id) {
            changedAt[id] = date
        }
        items = new
        forgetOldRemovals(now: date)
    }

    /// Combines this (local) copy with the one from iCloud. For each item the side that changed
    /// it last wins; an item only one side has heard of is kept; on a tie iCloud wins. Order:
    /// iCloud's, followed by items only this device has.
    public func merged(withCloud cloud: SyncedList, now: Date = .now) -> SyncedList {
        let local = self
        let localItems = Dictionary(local.items.map { ($0.id.description, $0) }, uniquingKeysWith: { first, _ in first })
        let cloudItems = Dictionary(cloud.items.map { ($0.id.description, $0) }, uniquingKeysWith: { first, _ in first })

        func winner(_ id: String) -> Element? {
            let localKnows = localItems[id] != nil || local.changedAt[id] != nil
            let cloudKnows = cloudItems[id] != nil || cloud.changedAt[id] != nil
            guard localKnows, cloudKnows else { return localItems[id] ?? cloudItems[id] }
            let localDate = local.changedAt[id] ?? .distantPast
            let cloudDate = cloud.changedAt[id] ?? .distantPast
            return localDate > cloudDate ? localItems[id] : cloudItems[id]
        }

        var ids: [String] = []
        var seen = Set<String>()
        for id in cloud.items.map(\.id.description) + local.items.map(\.id.description) where seen.insert(id).inserted {
            ids.append(id)
        }
        var result = SyncedList(items: ids.compactMap(winner), changedAt: local.changedAt)
        result.changedAt.merge(cloud.changedAt) { max($0, $1) }
        result.forgetOldRemovals(now: now)
        return result
    }

    private mutating func forgetOldRemovals(now: Date) {
        let present = Set(items.map(\.id.description))
        let cutoff = now.addingTimeInterval(-Self.removalMemory)
        changedAt = changedAt.filter { present.contains($0.key) || $0.value >= cutoff }
    }
}
