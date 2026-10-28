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
        try await ClipboardSyncFileTransfer.verify(prepared.descriptor, directory: prepared.uploadDirectory,
            account: basis.account, control: basis.control, key: key)
        let root = syncWorkingRoot.appendingPathComponent("Conflict Versions", isDirectory: true)
        let output = try await ClipboardSyncFilePublication.construct(descriptor: prepared.descriptor,
            encryptedDirectory: prepared.uploadDirectory, root: root, account: basis.account, control: basis.control, key: key, faults: faultInjector)
        defer { ClipboardSyncFilePublication.discard(output) }
        try await admitSyncFilePublication(generation, account: basis.account, control: basis.control, services: services)
        try linkedRead { database in
            try Self.validateConflictBasis(fileConflictBasis(entryID: .init(snapshot.entryID), objectID: snapshot.objectID, in: database), snapshot: snapshot)
        }
        let published = try ClipboardSyncFilePublication.publish(output, descriptor: prepared.descriptor,
            root: root, accountID: basis.account.identifier, faults: faultInjector)
        try await ClipboardSyncFilePublication.verifyPublished(published, candidate: output, faults: faultInjector)
        try await admitSyncFilePublication(generation, account: basis.account, control: basis.control, services: services)
        try syncWrite { database in
            try Self.validateConflictBasis(fileConflictBasis(entryID: .init(snapshot.entryID), objectID: snapshot.objectID, in: database), snapshot: snapshot)
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

    static let automaticFileConflictDownload = """
        EXISTS(SELECT 1 FROM clipboard_sync_file_auto_candidates AS candidate
          WHERE candidate.account_id = version.account_id AND candidate.epoch = version.epoch
            AND candidate.object_id = version.object_id AND candidate.version_id = version.version_id AND candidate.completed = 0)
        """

    /// The size rule applies to every conflicting head, including heads which
    /// are not selected. Receiving those bytes does not choose their contents.
    func stageAutomaticFileConflictDownloads(account: ClipboardSyncAccount, control: ClipboardSyncControl) throws {
        try syncWrite { database in
            let objects = try String.fetchAll(database, SQLRequest<String>(literal: """
                SELECT DISTINCT member.object_id FROM clipboard_sync_file_members AS member
                JOIN clipboard_entries AS entry ON entry.id = member.entry_id
                WHERE member.account_id = \(account.identifier) AND member.epoch = \(control.epoch.uuidString)
                  AND \(SQL(sql: Self.liveSyncFileMember))
                  AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier)))
                """))
            for object in objects {
                let rows = try Row.fetchAll(database, sql: """
                    SELECT version_id, parents, descriptor FROM clipboard_sync_file_versions
                    WHERE account_id = ? AND epoch = ? AND object_id = ?
                    """, arguments: [account.identifier, control.epoch.uuidString, object])
                let nodes = try rows.map { row -> ClipboardSyncVersionNode in
                    guard let id = UUID(uuidString: row["version_id"]) else { throw ClipboardSyncServiceError.corruptData }
                    return .init(id: id, parents: Set(try JSONDecoder().decode([UUID].self, from: row["parents"])))
                }
                let heads = ClipboardSyncVersionGraph.heads(nodes)
                guard heads.count > 1, ClipboardSyncVersionGraph.isComplete(nodes),
                      let current = try String.fetchOne(database, sql: """
                        SELECT current_version_id FROM clipboard_sync_file_selections WHERE account_id = ? AND epoch = ? AND object_id = ?
                        """, arguments: [account.identifier, control.epoch.uuidString, object]) else { continue }
                for row in rows {
                    let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"])
                    guard heads.contains(descriptor.versionID), descriptor.versionID.uuidString != current,
                          descriptor.state == .available, let size = descriptor.originalByteCount,
                          size <= Self.automaticSyncFileDownloadBytes else { continue }
                    try database.execute(sql: """
                        INSERT OR IGNORE INTO clipboard_sync_file_auto_candidates(account_id, epoch, object_id, version_id)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [account.identifier, control.epoch.uuidString, object, descriptor.versionID.uuidString])
                }
            }
        }
    }

    func isFileConflictDownload(_ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID) throws -> Bool {
        try linkedRead { database in
            try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins
                  WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ? AND download_requested = 1)
                  OR EXISTS(SELECT 1 FROM clipboard_sync_file_auto_candidates
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?)
                """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString,
                    account.identifier, epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString]) ?? false
        }
    }

    func syncFilePublicationRoot(_ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID) throws -> URL {
        try isFileConflictDownload(descriptor, account: account, epoch: epoch)
            ? syncWorkingRoot.appendingPathComponent("Conflict Versions", isDirectory: true) : syncWorkingRoot
    }
}
