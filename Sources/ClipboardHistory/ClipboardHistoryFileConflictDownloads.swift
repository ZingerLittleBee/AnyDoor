import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func requestFileConflictDownload(_ plan: ClipboardHistoryFileConflictPlan, versionID: UUID) async throws {
        try await waitForWriteTurn()
        let generation = syncGeneration
        try admitSync(generation)
        let retained = try linkedRead { database -> (ClipboardSyncFileConflictSnapshot, ClipboardSyncConflictVersion)? in
            guard let data = try Data.fetchOne(database, sql: "SELECT snapshot FROM clipboard_sync_file_conflict_plans WHERE id = ?", arguments: [plan.id.uuidString]) else {
                throw ClipboardHistoryFileConflictError.stalePlan
            }
            let snapshot = try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: data)
            let basis = try fileConflictBasis(entryID: .init(snapshot.entryID), objectID: snapshot.objectID, in: database)
            try Self.validateConflictBasis(basis, snapshot: snapshot)
            guard snapshot.heads.contains(versionID), let version = basis.versions.first(where: { $0.descriptor.versionID == versionID }) else {
                throw ClipboardHistoryFileConflictError.candidateUnavailable
            }
            return version.prepared == nil ? nil : (snapshot, version)
        }
        if let (snapshot, version) = retained {
            try await restoreRetainedConflictCandidate(version, snapshot: snapshot, generation: generation)
            return
        }
        try syncWrite { database in
            guard let data = try Data.fetchOne(database, sql: "SELECT snapshot FROM clipboard_sync_file_conflict_plans WHERE id = ?", arguments: [plan.id.uuidString]) else {
                throw ClipboardHistoryFileConflictError.stalePlan
            }
            let snapshot = try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: data)
            let basis = try fileConflictBasis(entryID: .init(snapshot.entryID), objectID: snapshot.objectID, in: database)
            try Self.validateConflictBasis(basis, snapshot: snapshot)
            guard snapshot.heads.contains(versionID), let version = basis.versions.first(where: { $0.descriptor.versionID == versionID }),
                  version.descriptor.state == .available else { throw ClipboardHistoryFileConflictError.candidateUnavailable }
            try validateSyncFileDescriptor(version.descriptor, epoch: snapshot.epoch, keyID: snapshot.keyID)
            try Self.pinFileConflictVersion(versionID, planID: plan.id, snapshot: snapshot, in: database)
            try database.execute(sql: "UPDATE clipboard_sync_file_conflict_pins SET download_requested = 1, download_completed = 0 WHERE plan_id = ? AND version_id = ?",
                arguments: [plan.id.uuidString, versionID.uuidString])
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_downloads(account_id, epoch, object_id, version_id, authorized)
                VALUES (?, ?, ?, ?, 1) ON CONFLICT(account_id, epoch, object_id, version_id) DO UPDATE SET authorized = 1, failure = NULL
                """, arguments: [snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString, versionID.uuidString])
            // The version's existing completion and linked file stay usable.
            // A separate candidate cursor requests reconstruction apart from it.
        }
        await retrySync()
    }

    private func restoreRetainedConflictCandidate(_ version: ClipboardSyncConflictVersion,
        snapshot: ClipboardSyncFileConflictSnapshot, generation: UInt64) async throws {
        guard let prepared = version.prepared, let owner = version.retainedPlanID, let services = syncServices else {
            throw ClipboardHistoryFileConflictError.candidateUnavailable
        }
        let basis = try linkedRead { try fileConflictBasis(entryID: .init(snapshot.entryID), objectID: snapshot.objectID, in: $0) }
        try await admitSyncFilePublication(generation, account: basis.account, control: basis.control, services: services)
        guard let key = try await services.keys.load(account: basis.account, keyID: basis.control.keyID), key.count == 32 else { throw ClipboardSyncServiceError.keyUnavailable }
        try await Self.verifyPreparedFileVersion(prepared, account: basis.account, control: basis.control, key: key)
        let root = syncWorkingRoot.appendingPathComponent("Conflict Versions", isDirectory: true)
        let output = try await ClipboardSyncFilePublication.construct(descriptor: prepared.descriptor,
            encryptedDirectory: prepared.uploadDirectory, root: root, account: basis.account, control: basis.control, key: key)
        defer { ClipboardSyncFilePublication.discard(output) }
        try await admitSyncFilePublication(generation, account: basis.account, control: basis.control, services: services)
        try syncWrite { database in
            try Self.validateConflictBasis(fileConflictBasis(entryID: .init(snapshot.entryID), objectID: snapshot.objectID, in: database), snapshot: snapshot)
            let published = try ClipboardSyncFilePublication.publish(output, descriptor: prepared.descriptor,
                root: root, accountID: basis.account.identifier, faults: faultInjector)
            guard let data = try Data.fetchOne(database, sql: "SELECT journal FROM clipboard_sync_file_resolutions WHERE plan_id = ? AND phase = 'needsReview'", arguments: [owner.uuidString]) else {
                throw ClipboardHistoryFileConflictError.stalePlan
            }
            var journal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: data)
            guard let index = journal.prepared.firstIndex(where: { $0.descriptor.versionID == prepared.descriptor.versionID }) else { throw ClipboardSyncServiceError.corruptData }
            journal.prepared[index] = .init(descriptor: prepared.descriptor, parents: prepared.parents,
                uploadDirectory: prepared.uploadDirectory, sourceURL: published.url, bookmark: published.bookmark,
                identity: published.identity, publication: prepared.publication)
            try database.execute(sql: "UPDATE clipboard_sync_file_resolutions SET journal = ? WHERE plan_id = ?",
                arguments: [try JSONEncoder().encode(journal), owner.uuidString])
        }
        publishMutation()
    }

    static let pinnedFileConflictDownload = """
        EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins AS pin
          WHERE pin.account_id = version.account_id AND pin.epoch = version.epoch
            AND pin.object_id = version.object_id AND pin.version_id = version.version_id
            AND pin.download_requested = 1 AND pin.download_completed = 0)
        """

    func isFileConflictDownload(_ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID) throws -> Bool {
        try linkedRead { database in
            try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins
                  WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ? AND download_requested = 1)
                """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString]) ?? false
        }
    }

    func syncFilePublicationRoot(_ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID) throws -> URL {
        try isFileConflictDownload(descriptor, account: account, epoch: epoch)
            ? syncWorkingRoot.appendingPathComponent("Conflict Versions", isDirectory: true) : syncWorkingRoot
    }
}
