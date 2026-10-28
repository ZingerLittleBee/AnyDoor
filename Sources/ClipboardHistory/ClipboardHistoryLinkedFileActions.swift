import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func reassociateFileLocation(_ request: ClipboardHistoryFileLocationReassociation) async throws -> ClipboardHistoryLinkedFileLocation {
        let generation = syncGeneration
        let baseline = try linkedRead { try Self.linkedFileActionRow(request.selection, in: $0) }
        guard (baseline["applying_version_id"] as String?) == nil else { throw ClipboardHistoryModuleError.operationUnavailable }
        let inspection = Task.detached(priority: .userInitiated) { try ClipboardLinkedFileIO.inspect(request.url) }
        let proof = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        try await waitForWriteTurn()
        guard generation == syncGeneration, proof.stamp.matches(proof.url) else { throw ClipboardHistoryModuleError.operationUnavailable }
        let result = try syncWrite { database in
            let current = try Self.linkedFileActionRow(request.selection, in: database)
            guard (current["account_id"] as String) == (baseline["account_id"] as String),
                  (current["epoch"] as String) == (baseline["epoch"] as String),
                  (current["applying_version_id"] as String?) == nil else { throw ClipboardHistoryModuleError.operationUnavailable }
            let occupied = try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_linked_locations
                WHERE account_id = ? AND epoch = ? AND id != ? AND (path = ? OR identity = ?))
                """, arguments: [current["account_id"] as String, current["epoch"] as String,
                    request.selection.locationID.uuidString, proof.url.path, proof.identity]) == true
            guard !occupied else { throw ClipboardHistoryModuleError.fileLocationAlreadyAssociated }
            let digest: Data = current["base_digest"]
            try database.execute(sql: """
                UPDATE clipboard_sync_linked_locations SET path = ?, bookmark = ?, identity = ?, native_identity = ?,
                  observed_digest = ?, state = ?, pending_version_id = NULL, revision = revision + 1 WHERE id = ?
                """, arguments: [proof.url.path, proof.bookmark, proof.identity, try proof.nativeIdentity?.encoded(),
                    proof.digest, proof.digest == digest ? "current" : "localChanges", request.selection.locationID.uuidString])
            try Self.bumpHistoryRevision(in: database)
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM clipboard_sync_linked_locations WHERE id = ?",
                arguments: [request.selection.locationID.uuidString]) else { throw ClipboardHistoryModuleError.operationUnavailable }
            return try Self.linkedFileLocation(row)
        }
        cancelLinkedFileObservation(request.selection.locationID)
        publishMutation()
        if !syncSuspended { await retrySync() }
        return result
    }

    public func setFileLocationPaused(_ selection: ClipboardHistoryFileLocationSelection, paused: Bool) async throws {
        try await waitForWriteTurn()
        try syncWrite { database in
            let row = try Self.linkedFileActionRow(selection, in: database)
            let state: String = row["state"]
            guard state != "detached", state != "identityUncertain" else { throw ClipboardHistoryModuleError.operationUnavailable }
            try database.execute(sql: """
                UPDATE clipboard_sync_linked_locations SET state = ?, revision = revision + 1 WHERE id = ?
                """, arguments: [paused ? "paused" : "unavailable", selection.locationID.uuidString])
            try Self.bumpHistoryRevision(in: database)
        }
        cancelLinkedFileObservation(selection.locationID)
        publishMutation()
        if !paused, !syncSuspended { await retrySync() }
    }

    static func linkedFileActionRow(_ selection: ClipboardHistoryFileLocationSelection, in database: Database) throws -> Row {
        guard let accountID = try String.fetchOne(database, sql: "SELECT account_id FROM clipboard_sync_settings WHERE id = 1"),
              let encoded = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [accountID]),
              let control = try JSONDecoder().decode(ClipboardSyncAccountState.self, from: encoded).control,
              control.phase == "active",
              let row = try Row.fetchOne(database, SQLRequest<Row>(literal: """
                SELECT location.* FROM clipboard_sync_linked_locations AS location
                JOIN clipboard_sync_file_members AS member ON member.account_id = location.account_id
                  AND member.epoch = location.epoch AND member.object_id = location.object_id
                JOIN clipboard_entries AS entry ON entry.id = member.entry_id
                WHERE location.id = \(selection.locationID.uuidString) AND location.account_id = \(accountID)
                  AND location.epoch = \(control.epoch.uuidString)
                  AND entry.id = \(selection.entryID.value.uuidString.lowercased())
                  AND \(SQL(sql: liveSyncFileMember)) AND (\(syncEntryPublicationAuthority(accountID: accountID)))
                """)), (row["revision"] as UInt64) == selection.expectedRevision else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return row
    }

    private func cancelLinkedFileObservation(_ id: UUID) {
        linkedFileObservers.removeValue(forKey: id)?.cancel()
        linkedFileObservationTasks.removeValue(forKey: id)?.cancel()
        linkedFileObservationRevisions.removeValue(forKey: id)
        linkedFileIdentityEvents.removeValue(forKey: id)
    }
}
