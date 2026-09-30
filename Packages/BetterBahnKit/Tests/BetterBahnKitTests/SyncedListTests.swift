import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct SyncedListTests {
    struct Item: Codable, Sendable, Identifiable, Equatable {
        var id: String
        var value = 0
    }

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var t1: Date { t0.addingTimeInterval(60) }
    var t2: Date { t0.addingTimeInterval(120) }

    private func ids(_ list: SyncedList<Item>) -> [String] { list.items.map(\.id) }

    /// Two devices that both had favourites before syncing existed: nothing gets lost, whichever
    /// device's copy iCloud ends up holding.
    @Test func firstSyncKeepsItemsFromBothDevices() {
        let phone = SyncedList(items: [Item(id: "a"), Item(id: "b")])
        let pad = SyncedList(items: [Item(id: "b"), Item(id: "c")])
        #expect(ids(phone.merged(withCloud: pad, now: t0)) == ["b", "c", "a"])
        #expect(ids(pad.merged(withCloud: phone, now: t0)) == ["a", "b", "c"])
    }

    @Test func removalOnAnotherDeviceIsTakenOver() {
        var cloud = SyncedList(items: [Item(id: "a"), Item(id: "b")])
        cloud.record(from: cloud.items, to: [Item(id: "a")], at: t1)
        let local = SyncedList(items: [Item(id: "a"), Item(id: "b")])
        #expect(ids(local.merged(withCloud: cloud, now: t1)) == ["a"])
    }

    /// A device that still has the item (and never touched it) doesn't bring it back.
    @Test func removalIsNotUndoneByAStaleCopy() {
        var local = SyncedList(items: [Item(id: "a"), Item(id: "b")])
        local.record(from: local.items, to: [Item(id: "a")], at: t1)
        let staleCloud = SyncedList(items: [Item(id: "a"), Item(id: "b")])
        let merged = local.merged(withCloud: staleCloud, now: t1)
        #expect(ids(merged) == ["a"])
        #expect(merged.changedAt["b"] == t1)
    }

    @Test func itemAddedAgainAfterRemovalComesBack() {
        var cloud = SyncedList(items: [Item(id: "a")])
        cloud.record(from: cloud.items, to: [], at: t1)
        var local = cloud
        local.record(from: [], to: [Item(id: "a")], at: t2)
        #expect(ids(local.merged(withCloud: cloud, now: t2)) == ["a"])
        #expect(ids(cloud.merged(withCloud: local, now: t2)) == ["a"])
    }

    @Test func newerChangeWinsPerItem() {
        var local = SyncedList(items: [Item(id: "a"), Item(id: "b")])
        var cloud = local
        local.record(from: local.items, to: [Item(id: "a", value: 1), Item(id: "b")], at: t2)
        cloud.record(from: cloud.items, to: [Item(id: "a", value: 2), Item(id: "b", value: 2)], at: t1)
        let merged = local.merged(withCloud: cloud, now: t2)
        #expect(merged.items == [Item(id: "a", value: 1), Item(id: "b", value: 2)])
        #expect(merged.changedAt == ["a": t2, "b": t1])
    }

    @Test func unchangedItemsKeepTheirDate() {
        var list = SyncedList(items: [Item(id: "a"), Item(id: "b")])
        list.record(from: list.items, to: [Item(id: "a"), Item(id: "b", value: 1)], at: t1)
        #expect(list.changedAt == ["b": t1])
    }

    @Test func oldRemovalsAreForgotten() {
        var list = SyncedList(items: [Item(id: "a"), Item(id: "b")])
        list.record(from: list.items, to: [Item(id: "a")], at: t0)
        #expect(list.changedAt["b"] == t0)
        list.record(from: list.items, to: [Item(id: "a"), Item(id: "c")],
                    at: t0.addingTimeInterval(SyncedList<Item>.removalMemory + 1))
        #expect(list.changedAt["b"] == nil)
        #expect(list.changedAt["c"] != nil)
    }
}
