import Foundation
import GRDB

extension ClipboardHistoryModule {
    /// Uses the shared content authority at dispatch time as well as freezing
    /// time. Retained outbox metadata remains available to the cleanup ledger.
    static func syncFileOutboxAuthority(accountID: String) -> SQL {
        """
        ((outbox.kind != 'fileBody' AND NOT EXISTS (SELECT 1 FROM clipboard_sync_file_versions AS version
            WHERE version.publication_record_id = outbox.record_id))
          OR EXISTS (SELECT 1 FROM clipboard_sync_file_members AS member
            JOIN clipboard_entries AS entry ON entry.id = member.entry_id
            JOIN clipboard_representations AS representation ON representation.entry_id = member.entry_id
              AND representation.item_index = member.item_index AND representation.representation_index = member.representation_index
            WHERE member.account_id = outbox.account_id AND member.epoch = outbox.epoch
              AND member.object_id = outbox.subject_id AND representation.kind = 'fileReference'
              AND (\(Self.syncEntryPublicationAuthority(accountID: accountID)))))
        """
    }

    static func syncFileTransferSummary(_ descriptor: ClipboardSyncFileDescriptor, accountID: String, epoch: String,
        in database: Database) throws -> (bytes: Int64, failure: ClipboardHistorySyncFileFailure?, requested: Bool, uploadPending: Bool) {
        if let body = descriptor.body, let upload = try Row.fetchOne(database, sql: """
            SELECT transfer.completed_bytes, transfer.failure, outbox.acknowledged
            FROM clipboard_sync_file_uploads AS transfer JOIN clipboard_sync_outbox AS outbox USING(record_id)
            WHERE record_id = ? AND account_id = ? AND epoch = ?
            """, arguments: [body.recordID, accountID, epoch]), !(upload["acknowledged"] as Bool) {
            let encrypted: Int64 = upload["completed_bytes"]
            // Progress callbacks count ciphertext; discard each completed unit's authentication overhead.
            let units = min(Int64(body.chunkCount), (encrypted + Int64(ClipboardSyncFileTransfer.maximumEncryptedSegmentBytes) - 1)
                / Int64(ClipboardSyncFileTransfer.maximumEncryptedSegmentBytes))
            return (max(0, encrypted - units * 28), (upload["failure"] as String?).flatMap(ClipboardHistorySyncFileFailure.init), false, true)
        }
        let download = try Row.fetchOne(database, sql: """
            SELECT completed_bytes, authorized, failure FROM clipboard_sync_file_downloads
            WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
            """, arguments: [accountID, epoch, descriptor.objectID.uuidString, descriptor.versionID.uuidString])
        return (download?["completed_bytes"] ?? 0,
            (download?["failure"] as String?).flatMap(ClipboardHistorySyncFileFailure.init), download?["authorized"] ?? false, false)
    }

    func recordSyncFileFailure(_ error: Error, descriptor: ClipboardSyncFileDescriptor,
        account: ClipboardSyncAccount, epoch: UUID, generation: UInt64) throws {
        guard generation == syncGeneration, !syncSuspended, !(error is CancellationError) else { return }
        let failure = Self.syncFileFailure(error)
        try syncWrite { database in
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_downloads(account_id, epoch, object_id, version_id, failure)
                VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id, epoch, object_id, version_id) DO UPDATE SET failure = excluded.failure
                """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString,
                    descriptor.versionID.uuidString, failure.rawValue])
            try Self.bumpHistoryRevision(in: database)
        }
        publishMutation()
    }

    func recordSyncFileUploadFailure(_ error: Error, record: ClipboardSyncRemoteRecord, generation: UInt64) throws {
        guard record.kind == .fileBody, generation == syncGeneration, !syncSuspended, !(error is CancellationError) else { return }
        try syncWrite { database in
            try database.execute(sql: "UPDATE clipboard_sync_file_uploads SET failure = ? WHERE record_id = ?",
                arguments: [Self.syncFileFailure(error).rawValue, record.recordID])
            try Self.bumpHistoryRevision(in: database)
        }
        publishMutation()
    }

    static func syncFileFailure(_ error: Error) -> ClipboardHistorySyncFileFailure {
        switch error as? ClipboardSyncServiceError {
        case .network, .conflict: .network
        case .quota: .quota
        case .corruptData: .corruptData
        case .accessDenied: .accessDenied
        case .accountChanged, .accountUnavailable: .accountChanged
        case .keyLocked, .keyUnavailable: .keyUnavailable
        case .capabilityUnavailable, .missingRemoteState, .recordUnavailable, .unsupportedVersion: .unavailable
        case .localStorage, nil: .localStorage
        }
    }

    /// Ownership survives both acknowledgement and partial provider writes. The
    /// withdrawal ledger must copy these records before removing file membership.
    func syncFileOwnedTransfers(entryID: ClipboardHistoryEntryID, accountID: String, epoch: UUID) throws -> [ClipboardSyncOwnedFileTransfer] {
        try requiredDatabase().read { database in
            try Row.fetchAll(database, sql: """
                SELECT DISTINCT outbox.subject_id, outbox.metadata FROM clipboard_sync_outbox AS outbox
                JOIN clipboard_sync_file_members AS member ON member.account_id = outbox.account_id
                  AND member.epoch = outbox.epoch AND member.object_id = outbox.subject_id
                WHERE member.entry_id = ? AND outbox.account_id = ? AND outbox.epoch = ? AND outbox.kind = 'fileBody'
                """, arguments: [entryID.value.uuidString.lowercased(), accountID, epoch.uuidString]).map { row in
                guard let objectID = UUID(uuidString: row["subject_id"]) else { throw ClipboardSyncServiceError.corruptData }
                let record = try JSONDecoder().decode(ClipboardSyncRemoteRecord.self, from: row["metadata"])
                return .init(objectID: objectID, versionID: record.operationID, record: record)
            }
        }
    }

    func syncFileVersionIsCommitted(objectID: UUID, versionID: UUID) throws -> Bool {
        try requiredDatabase().read { database in
            guard let context = try syncFileContext(in: database), let row = try Row.fetchOne(database, sql: """
                SELECT descriptor, publication_record_id FROM clipboard_sync_file_versions
                WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                """, arguments: [context.account.identifier, context.control.epoch.uuidString, objectID.uuidString, versionID.uuidString]),
                  let body = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"]).body else { return false }
            let publication: String? = try row["publication_record_id"] ?? String.fetchOne(database, sql: """
                SELECT entry.record_id FROM clipboard_sync_entries AS entry
                JOIN clipboard_sync_file_members AS member ON member.account_id = entry.account_id
                  AND member.epoch = entry.epoch AND member.entry_id = entry.local_entry_id
                WHERE member.account_id = ? AND member.epoch = ? AND member.object_id = ? AND member.version_id = ?
                """, arguments: [context.account.identifier, context.control.epoch.uuidString, objectID.uuidString, versionID.uuidString])
            guard let publication else { return false }
            let bodyAcknowledged = try Bool.fetchOne(database, sql: "SELECT acknowledged FROM clipboard_sync_outbox WHERE record_id = ?",
                arguments: [body.recordID]) ?? true
            let publicationAcknowledged = try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_outbox WHERE record_id = ? AND acknowledged = 1)
                  OR EXISTS(SELECT 1 FROM clipboard_sync_inbox WHERE account_id = ? AND epoch = ? AND record_id = ?)
                """, arguments: [publication, context.account.identifier, context.control.epoch.uuidString, publication]) ?? false
            return bodyAcknowledged && publicationAcknowledged
        }
    }
}
