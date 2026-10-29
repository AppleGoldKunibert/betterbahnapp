import Foundation
import Testing
@testable import BetterBahnKit

/// Saved journeys synced as CloudKit records (#427).
@Suite struct RecordSyncTests {
    private struct Item: Identifiable, Equatable {
        let id: Int
        var name: String
    }

    @Test func changesNameAddedEditedAndRemovedItems() {
        let old = [Item(id: 1, name: "a"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]
        let new = [Item(id: 1, name: "a"), Item(id: 2, name: "B"), Item(id: 4, name: "d")]
        let changes = RecordSync.changes(from: old, to: new)
        #expect(changes.saved == ["2", "4"])
        #expect(changes.removed == ["3"])
    }

    @Test func unchangedListHasNoChanges() {
        let list = [Item(id: 1, name: "a"), Item(id: 2, name: "b")]
        #expect(RecordSync.changes(from: list, to: list).isEmpty)
        // Reordering alone uploads nothing.
        #expect(RecordSync.changes(from: list, to: list.reversed()).isEmpty)
    }

    @Test func firstUploadSavesEverything() {
        let list = [Item(id: 1, name: "a"), Item(id: 2, name: "b")]
        #expect(RecordSync.changes(from: [], to: list).saved == ["1", "2"])
    }

    @Test func laterChangeWins() {
        let earlier = Date(timeIntervalSince1970: 1_790_000_000)
        let later = earlier.addingTimeInterval(60)
        #expect(RecordSync.remoteWins(local: earlier, remote: later))
        #expect(!RecordSync.remoteWins(local: later, remote: earlier))
        #expect(RecordSync.remoteWins(local: earlier, remote: earlier))
        #expect(RecordSync.remoteWins(local: nil, remote: earlier))
        #expect(!RecordSync.remoteWins(local: earlier, remote: nil))
    }
}
