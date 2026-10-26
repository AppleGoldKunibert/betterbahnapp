import BetterBahnKit
import CloudKit
import Foundation
import os

/// Syncs the saved journeys through the user's private CloudKit database, one record per journey (#427). They used to
/// sync as one value in the iCloud key-value store (`CloudSync`), which holds 1 MB in total: a long journey history
/// outgrew it, and then no journey synced at all. Settings, favourites, recent searches and regular trips stay there.
///
/// `CKSyncEngine` keeps track of what to fetch and send. Each record carries when the journey last changed on the device
/// that sent it; when both sides changed a journey, the later change wins (`RecordSync.remoteWins`).
@MainActor
final class JourneyCloudSync {
    private weak var model: AppModel?
    private var engine: CKSyncEngine?
    /// When each journey was last changed (here, or on the device it came from), by `SavedJourney.id`.
    private var changedAt: [String: Date]
    /// The CloudKit system fields of each journey's record as last seen, so a save updates that record.
    private var systemFields: [String: Data]
    /// Local changes made before the engine started.
    private var waiting = RecordSync.Changes(saved: [], removed: [])
    private var isApplyingRemote = false

    nonisolated static let zoneName = "SavedJourneys"
    nonisolated static let recordType = "SavedJourney"
    nonisolated static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }
    nonisolated private static let stateKey = "cloudKit-journeyState"
    private static let datesKey = "cloudKit-journeyDates"
    private static let recordsKey = "cloudKit-journeyRecords"
    nonisolated static let log = Logger(subsystem: "de.goldkunibert.BetterBahn", category: "JourneyCloudSync")

    init() {
        changedAt = Storage.load(key: Self.datesKey) ?? [:]
        systemFields = Storage.load(key: Self.recordsKey) ?? [:]
    }

    /// Starts syncing; on the first start every journey saved here is uploaded.
    func start(model: AppModel) {
        guard engine == nil else { return }
        self.model = model
        let state: CKSyncEngine.State.Serialization? = Storage.load(key: Self.stateKey)
        let configuration = CKSyncEngine.Configuration(database: CKContainer.default().privateCloudDatabase,
                                                       stateSerialization: state, delegate: self)
        engine = CKSyncEngine(configuration)
        Self.log.info("Started (\(state == nil ? "first start" : "resumed", privacy: .public)) with \(model.savedJourneys.count) journeys")
        if state == nil {
            uploadAll()
        } else {
            queue(waiting)
        }
        waiting = RecordSync.Changes(saved: [], removed: [])
        Task {
            let status = try? await CKContainer.default().accountStatus()
            // 1 available, 3 no account, 2 restricted, 4 temporarily unavailable, 0 unknown.
            Self.log.info("iCloud account status: \(status?.rawValue ?? -1)")
        }
        // The scene was already active before the engine existed: take over what changed meanwhile right away.
        fetch()
    }

    /// Looks for journeys changed on the other devices (when the app comes to the foreground).
    func fetch() {
        guard let engine else { return }
        Task {
            do { try await engine.fetchChanges() } catch { Self.log.error("Fetch failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Call from `savedJourneys`' `didSet`: uploads what was added or changed and deletes what was removed.
    func localChange(from old: [SavedJourney], to new: [SavedJourney]) {
        guard !isApplyingRemote else { return }
        let changes = RecordSync.changes(from: old, to: new)
        guard !changes.isEmpty else { return }
        let now = Date.now
        for id in changes.saved { changedAt[id] = now }
        for id in changes.removed { changedAt[id] = nil }
        saveDates()
        if engine == nil {
            waiting.saved = Array(Set(waiting.saved).union(changes.saved).subtracting(changes.removed))
            waiting.removed = Array(Set(waiting.removed).union(changes.removed).subtracting(changes.saved))
        } else {
            queue(changes)
        }
    }

    private func queue(_ changes: RecordSync.Changes) {
        guard let engine, !changes.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: changes.saved.map { .saveRecord(Self.recordID($0)) }
            + changes.removed.map { .deleteRecord(Self.recordID($0)) })
    }

    private func uploadAll() {
        guard let engine, let model else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        queue(RecordSync.Changes(saved: model.savedJourneys.map(\.id.uuidString), removed: []))
    }

    nonisolated private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    // MARK: Applying the server's changes

    /// Takes over journeys fetched from the server (or sent back in a conflict), unless this device changed them later.
    fileprivate func apply(_ fetched: [RemoteJourney], deleted: [String], pendingSaves: Set<String>) {
        guard let model else { return }
        var journeys = model.savedJourneys
        var changed = false
        for remote in fetched {
            systemFields[remote.name] = remote.systemFields
            guard let journey = remote.journey,
                  RecordSync.remoteWins(local: changedAt[remote.name], remote: remote.changedAt) else { continue }
            changedAt[remote.name] = remote.changedAt
            if let index = journeys.firstIndex(where: { $0.id.uuidString == remote.name }) {
                if journeys[index] != journey {
                    journeys[index] = journey
                    changed = true
                }
            } else {
                journeys.append(journey)
                changed = true
            }
        }
        // A journey changed here since it was deleted elsewhere is uploaded again.
        for name in deleted where !pendingSaves.contains(name) {
            systemFields[name] = nil
            changedAt[name] = nil
            if let index = journeys.firstIndex(where: { $0.id.uuidString == name }) {
                journeys.remove(at: index)
                changed = true
            }
        }
        if changed {
            // Kept in order of departure, like a journey saved here: the lists show it that way.
            journeys.sort(by: SavedJourney.departsEarlier)
            isApplyingRemote = true
            model.savedJourneys = journeys
            isApplyingRemote = false
        }
        saveDates()
        saveRecords()
    }

    fileprivate func didSend(saved: [RemoteJourney], deleted: [String]) {
        for record in saved { systemFields[record.name] = record.systemFields }
        for name in deleted { systemFields[name] = nil }
        saveRecords()
    }

    /// Someone else saved the record first: the later change wins, ours is sent again on top of theirs.
    fileprivate func conflict(_ server: RemoteJourney) {
        if RecordSync.remoteWins(local: changedAt[server.name], remote: server.changedAt) {
            apply([server], deleted: [], pendingSaves: [])
        } else {
            systemFields[server.name] = server.systemFields
            saveRecords()
            queue(RecordSync.Changes(saved: [server.name], removed: []))
        }
    }

    fileprivate func resend(_ name: String, needsZone: Bool) {
        if needsZone {
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        } else {
            systemFields[name] = nil
            saveRecords()
        }
        queue(RecordSync.Changes(saved: [name], removed: []))
    }

    /// Another iCloud account, or none: what is known about the old account's records no longer applies. The
    /// journeys stay on this device and are uploaded to the account signed in next.
    fileprivate func accountChanged(signedIn: Bool) {
        systemFields = [:]
        saveRecords()
        if signedIn { uploadAll() }
    }

    /// The zone was deleted (the user removed the app's iCloud data): the journeys stay here. After an iCloud reset of
    /// the encrypted data they are uploaded again.
    fileprivate func zoneDeleted(reupload: Bool) {
        systemFields = [:]
        saveRecords()
        if reupload { uploadAll() }
    }

    /// What to send for the pending saves, read here and turned into records off the main actor.
    fileprivate func outgoing(_ names: [String]) -> [String: OutgoingJourney] {
        guard let model else { return [:] }
        let wanted = Set(names)
        var result: [String: OutgoingJourney] = [:]
        for journey in model.savedJourneys where wanted.contains(journey.id.uuidString) {
            let name = journey.id.uuidString
            result[name] = OutgoingJourney(journey: journey, changedAt: changedAt[name], systemFields: systemFields[name])
        }
        return result
    }

    private func saveDates() { Storage.saveInBackground(changedAt, key: Self.datesKey) }
    private func saveRecords() { Storage.saveInBackground(systemFields, key: Self.recordsKey) }
}

/// A journey as fetched from (or saved to) CloudKit, decoded off the main actor.
nonisolated private struct RemoteJourney: Sendable {
    let name: String
    let journey: SavedJourney?
    let changedAt: Date?
    let systemFields: Data

    init(_ record: CKRecord) {
        name = record.recordID.recordName
        changedAt = record["changedAt"] as? Date
        journey = (record["journey"] as? Data).flatMap(JourneyCloudSync.decode)
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        systemFields = coder.encodedData
    }
}

/// A journey to send, turned into its record off the main actor.
nonisolated private struct OutgoingJourney: Sendable {
    let journey: SavedJourney
    let changedAt: Date?
    let systemFields: Data?

    func record(_ id: CKRecord.ID) -> CKRecord? {
        guard let payload = JourneyCloudSync.encode(journey) else { return nil }
        var record: CKRecord?
        if let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            record = CKRecord(coder: coder)
            coder.finishDecoding()
        }
        let result = record ?? CKRecord(recordType: JourneyCloudSync.recordType, recordID: id)
        result["journey"] = payload
        result["changedAt"] = changedAt
        return result
    }
}

extension JourneyCloudSync {
    /// Compressed JSON, like the key-value store's values.
    nonisolated static func encode(_ journey: SavedJourney) -> Data? {
        guard let json = try? JSONEncoder().encode(journey) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    nonisolated static func decode(_ data: Data) -> SavedJourney? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(SavedJourney.self, from: json)
    }
}

// Explicitly nonisolated: the engine calls in from its own queue, the methods hop to the main actor themselves.
extension JourneyCloudSync: nonisolated CKSyncEngineDelegate {
    @concurrent nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Storage.save(update.stateSerialization, key: Self.stateKey)
        case .accountChange(let change):
            Self.log.info("Account change: \(String(describing: change.changeType), privacy: .public)")
            switch change.changeType {
            case .signIn:
                await accountChanged(signedIn: true)
            case .signOut, .switchAccounts:
                await accountChanged(signedIn: false)
            @unknown default:
                break
            }
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID.zoneName == Self.zoneName {
                await zoneDeleted(reupload: deletion.reason == .encryptedDataReset)
            }
        case .sentDatabaseChanges(let sent):
            Self.log.info("Sent zones: \(sent.savedZones.count) saved, \(sent.failedZoneSaves.count) failed")
            for failure in sent.failedZoneSaves {
                Self.log.error("Saving zone failed: \(String(describing: failure.error), privacy: .public)")
            }
        case .fetchedRecordZoneChanges(let changes):
            Self.log.info("Fetched \(changes.modifications.count) journeys, \(changes.deletions.count) deletions")
            let fetched = changes.modifications.map { RemoteJourney($0.record) }
            let deleted = changes.deletions.map(\.recordID.recordName)
            let pendingSaves = Set(syncEngine.state.pendingRecordZoneChanges.compactMap { change -> String? in
                if case .saveRecord(let id) = change { return id.recordName }
                return nil
            })
            await apply(fetched, deleted: deleted, pendingSaves: pendingSaves)
        case .sentRecordZoneChanges(let sent):
            Self.log.info("Sent \(sent.savedRecords.count) journeys, \(sent.failedRecordSaves.count) failed, \(sent.deletedRecordIDs.count) deleted")
            let saved = sent.savedRecords.map { RemoteJourney($0) }
            await didSend(saved: saved, deleted: sent.deletedRecordIDs.map(\.recordName))
            for failure in sent.failedRecordSaves {
                let name = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    if let server = failure.error.serverRecord { await conflict(RemoteJourney(server)) }
                case .zoneNotFound:
                    await resend(name, needsZone: true)
                case .unknownItem:
                    await resend(name, needsZone: false)
                default:
                    Self.log.error("Saving \(name, privacy: .public) failed: \(String(describing: failure.error), privacy: .public)")
                }
            }
        case .didFetchChanges:
            Self.log.info("Fetch done")
        default:
            break
        }
    }

    @concurrent nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let names = pending.compactMap { change -> String? in
            if case .saveRecord(let id) = change { return id.recordName }
            return nil
        }
        let outgoing = await outgoing(names)
        // A save whose journey is gone by now returns no record, which drops it.
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            outgoing[id.recordName]?.record(id)
        }
    }
}
