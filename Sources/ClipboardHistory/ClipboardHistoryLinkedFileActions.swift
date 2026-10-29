import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func reassociateFileLocation(_ request: ClipboardHistoryFileLocationReassociation) async throws -> ClipboardHistoryLinkedFileLocation {
        let generation = syncGeneration
        let baseline = try linkedRead { try Self.linkedFileActionRow(request.selection, in: $0) }
        let inspection = Task.detached(priority: .userInitiated) { try ClipboardLinkedFileIO.inspect(request.url) }
        let proof = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        try await waitForWriteTurn()
        guard generation == syncGeneration, proof.stamp.matches(proof.url) else { throw ClipboardHistoryModuleError.operationUnavailable }
        let result = try syncWrite { database in
            let current = try Self.linkedFileActionRow(request.selection, in: database)
            guard (current["account_id"] as String) == (baseline["account_id"] as String),
                  (current["epoch"] as String) == (baseline["epoch"] as String),
                  (current["base_version_id"] as String) == (baseline["base_version_id"] as String),
                  (current["base_digest"] as Data) == (baseline["base_digest"] as Data),
                  (current["identity"] as Data) == (baseline["identity"] as Data),
                  (current["applying_version_id"] as String?) == (baseline["applying_version_id"] as String?),
                  (current["applying_digest"] as Data?) == (baseline["applying_digest"] as Data?),
                  (current["replacement_identity"] as Data?) == (baseline["replacement_identity"] as Data?),
                  (current["replacement_path"] as String?) == (baseline["replacement_path"] as String?),
                  proof.stamp.matches(proof.url) else { throw ClipboardHistoryModuleError.operationUnavailable }
            let occupied = try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_linked_locations
                WHERE account_id = ? AND epoch = ? AND id != ? AND (path = ? OR identity = ?))
                """, arguments: [current["account_id"] as String, current["epoch"] as String,
                    request.selection.locationID.uuidString, proof.url.path, proof.identity]) == true
            guard !occupied else { throw ClipboardHistoryModuleError.fileLocationAlreadyAssociated }
            let journalBase = try Self.reassociatedJournalBase(current, proof: proof, in: database)
            let base: String = journalBase?.versionID ?? current["base_version_id"]
            let digest: Data = journalBase?.digest ?? current["base_digest"]
            guard proof.stamp.matches(proof.url) else { throw ClipboardHistoryModuleError.operationUnavailable }
            // Explicit reassociation retires uncertain exchange authority, not
            // either visible output. The revision also revokes a queued exchange
            // at its serialized final admission. A proven candidate retains its
            // authenticated base without inferring where an exchange happened.
            try database.execute(sql: """
                UPDATE clipboard_sync_linked_locations SET path = ?, bookmark = ?, identity = ?, native_identity = ?,
                  base_version_id = ?, base_digest = ?, observed_digest = ?, state = ?, pending_version_id = NULL, revision = revision + 1,
                  applying_version_id = NULL, applying_digest = NULL, replacement_path = NULL, replacement_identity = NULL WHERE id = ?
                """, arguments: [proof.url.path, proof.bookmark, proof.identity, try proof.nativeIdentity?.encoded(),
                    base, digest, proof.digest, proof.digest == digest ? "current" : "localChanges", request.selection.locationID.uuidString])
            try Self.completeLinkedSyncFileWork(request.selection.locationID, in: database)
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

    private static func reassociatedJournalBase(_ location: Row, proof: ClipboardLinkedFileProof,
        in database: Database) throws -> (versionID: String, digest: Data)? {
        guard let version: String = location["applying_version_id"], let versionID = UUID(uuidString: version),
              let digest: Data = location["applying_digest"], digest == proof.digest,
              let identity: Data = location["replacement_identity"], identity == proof.identity,
              (location["replacement_path"] as String?) != nil,
              let objectID = UUID(uuidString: location["object_id"]),
              let baseID = UUID(uuidString: location["base_version_id"]) else { return nil }
        let arguments: StatementArguments = [location["account_id"] as String, location["epoch"] as String, objectID.uuidString]
        guard let versionRow = try Row.fetchOne(database, sql: """
            SELECT version.descriptor FROM clipboard_sync_file_selections AS choice
            JOIN clipboard_sync_file_versions AS version USING(account_id, epoch, object_id)
            WHERE choice.account_id = ? AND choice.epoch = ? AND choice.object_id = ?
              AND choice.current_version_id = ? AND choice.complete_version_id = ?
              AND version.version_id = ? AND version.transfer_state = 'complete'
            """, arguments: arguments + [version, version, version]) else { return nil }
        let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: versionRow["descriptor"])
        guard descriptor.objectID == objectID, descriptor.versionID == versionID, descriptor.state == .available,
              descriptor.contentDigest == digest, descriptor.originalByteCount == proof.byteCount else { return nil }
        let rows = try Row.fetchAll(database, sql: """
            SELECT version_id, parents FROM clipboard_sync_file_versions
            WHERE account_id = ? AND epoch = ? AND object_id = ?
            """, arguments: arguments)
        let nodes = try rows.map { row -> ClipboardSyncVersionNode in
            guard let id = UUID(uuidString: row["version_id"]) else { throw ClipboardSyncServiceError.corruptData }
            return .init(id: id, parents: Set(try JSONDecoder().decode([UUID].self, from: row["parents"])))
        }
        // A complete DAG with one head makes the recorded base its ancestor.
        // A stale choice or another branch must still use normal reconciliation.
        guard nodes.contains(where: { $0.id == baseID }), ClipboardSyncVersionGraph.isComplete(nodes),
              ClipboardSyncVersionGraph.heads(nodes) == [versionID] else { return nil }
        return (version, digest)
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
