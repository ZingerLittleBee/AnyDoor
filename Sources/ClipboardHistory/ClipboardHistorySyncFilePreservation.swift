import Foundation
import GRDB

struct ClipboardSyncPreservedFileSource: Codable, Sendable {
    var location: ClipboardLinkedLocationSource
    let unpublished: Bool
    let capturedAt: Double
    let lastCapturedAt: Double
    let sourceBundleID: String?
    let sourceDisplayName: String?
    let provenance: String
    let favorite: Bool
    let tagIDs: [String]
    var frozen: ClipboardSyncPreparedFileVersion? = nil
    var account: ClipboardSyncAccount? = nil
    var control: ClipboardSyncControl? = nil
}

extension ClipboardHistoryModule {
    static func createSyncFilePreservationSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_preservations (
                id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, epoch TEXT NOT NULL,
                shared_id TEXT NOT NULL, source_id TEXT NOT NULL, source BLOB NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0, preserved_digest BLOB,
                UNIQUE(account_id, epoch, shared_id, source_id)
            );
            """)
    }

    static func captureSyncFilePreservations(sharedID: String, accountID: String, epoch: String, in database: Database) throws {
        guard let entry = try Row.fetchOne(database, sql: """
            SELECT entry.* FROM clipboard_sync_entries AS shared JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            WHERE shared.account_id = ? AND shared.epoch = ? AND shared.shared_id = ?
            """, arguments: [accountID, epoch, sharedID]) else { return }
        let entryID: String = entry["id"]
        let tags = try String.fetchAll(database, sql: "SELECT tag_id FROM clipboard_entry_tags WHERE entry_id = ?", arguments: [entryID])
        let locations = try Row.fetchAll(database, sql: """
            SELECT location.* FROM clipboard_sync_linked_locations AS location
            WHERE location.account_id = ? AND location.epoch = ? AND EXISTS (
                SELECT 1 FROM clipboard_sync_file_members AS member WHERE member.entry_id = ?
                  AND member.account_id = location.account_id AND member.epoch = location.epoch AND member.object_id = location.object_id)
            """, arguments: [accountID, epoch, entryID])
        var sources: [UUID: ClipboardSyncPreservedFileSource] = [:]
        for row in locations {
            let location = try linkedLocationSource(row)
            let unpublished = try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_file_versions AS version
                  JOIN clipboard_sync_outbox AS event ON event.record_id = version.publication_record_id
                  WHERE version.account_id = ? AND version.epoch = ? AND version.object_id = ?
                    AND version.version_id = ? AND event.acknowledged = 0)
                """, arguments: [accountID, epoch, location.objectID.uuidString, location.baseVersionID.uuidString]) ?? false
            let source = ClipboardSyncPreservedFileSource(location: location, unpublished: unpublished,
                capturedAt: entry["captured_at"], lastCapturedAt: entry["last_captured_at"],
                sourceBundleID: entry["source_bundle_id"], sourceDisplayName: entry["source_display_name"],
                provenance: entry["source_provenance"], favorite: entry["is_favorite"], tagIDs: tags)
            sources[location.objectID] = source
            try database.execute(sql: """
                INSERT OR IGNORE INTO clipboard_sync_file_preservations(id, account_id, epoch, shared_id, source_id, source)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString.lowercased(), accountID, epoch, sharedID, location.id.uuidString,
                    try JSONEncoder().encode(source)])
        }
        guard let data = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [accountID]) else { return }
        let state = try JSONDecoder().decode(ClipboardSyncAccountState.self, from: data)
        guard let control = state.control, control.epoch.uuidString == epoch else { return }
        for row in try Row.fetchAll(database, sql: """
            SELECT object_id, journal FROM clipboard_sync_file_resolutions AS resolution
            WHERE account_id = ? AND epoch = ? AND phase != 'complete' AND EXISTS (
              SELECT 1 FROM clipboard_sync_file_members AS member WHERE member.entry_id = ?
                AND member.account_id = resolution.account_id AND member.epoch = resolution.epoch AND member.object_id = resolution.object_id)
            """, arguments: [accountID, epoch, entryID]) {
            let journal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: row["journal"])
            for prepared in journal.prepared {
                guard var source = sources[prepared.descriptor.objectID], let body = prepared.descriptor.body else { continue }
                let committed = try Bool.fetchOne(database, sql: """
                    SELECT EXISTS(SELECT 1 FROM clipboard_sync_outbox WHERE record_id = ? AND acknowledged = 1)
                      AND EXISTS(SELECT 1 FROM clipboard_sync_outbox WHERE record_id = ? AND acknowledged = 1)
                    """, arguments: [body.recordID, prepared.publication.record.recordID]) ?? false
                guard !committed else { continue }
                source.frozen = prepared; source.account = state.account; source.control = control
                try database.execute(sql: """
                    INSERT OR IGNORE INTO clipboard_sync_file_preservations(id, account_id, epoch, shared_id, source_id, source)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString.lowercased(), accountID, epoch, sharedID,
                        "version:" + prepared.descriptor.versionID.uuidString, try JSONEncoder().encode(source)])
                for record in [body, prepared.publication.record] {
                    try rememberSyncFileRecord(record, objectID: prepared.descriptor.objectID.uuidString,
                        sharedID: sharedID, accountID: accountID, in: database)
                }
            }
        }
    }

    /// Local saved work is examined after deletion has revoked shared authority.
    /// The durable source snapshot survives member cascades and does not require
    /// cloud/key access or implicitly enable synchronization after restart.
    func resumeSyncFilePreservations() async throws {
        try await recoverLocalLinkedFileApplications()
        let epoch = storeEpoch
        let rows = try linkedRead { try Row.fetchAll($0, sql: "SELECT * FROM clipboard_sync_file_preservations WHERE completed = 0 ORDER BY id") }
        for row in rows {
            let id: String = row["id"]
            var source = try JSONDecoder().decode(ClipboardSyncPreservedFileSource.self, from: row["source"])
            if source.location.hasPendingApplication, let current = try linkedRead({ try Row.fetchOne($0,
                sql: "SELECT * FROM clipboard_sync_linked_locations WHERE id = ? AND account_id = ? AND epoch = ?",
                arguments: [source.location.id.uuidString, row["account_id"] as String, row["epoch"] as String]) }) {
                source.location = try Self.linkedLocationSource(current)
            }
            let destination = syncWorkingRoot.appendingPathComponent("Preserved Files", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true).appendingPathComponent(source.location.url.lastPathComponent)
            let proof: ClipboardLinkedFileProof?
            do { proof = try await preparePreservedSyncFile(source, destination: destination) }
            catch { continue } // Inaccessible or changing saved work stays durable and retryable.
            try await waitForWriteTurn()
            guard storeEpoch == epoch else { throw ClipboardHistoryModuleError.operationUnavailable }
            try syncWrite { database in
                guard try Bool.fetchOne(database, sql: "SELECT completed = 0 FROM clipboard_sync_file_preservations WHERE id = ?", arguments: [id]) == true else { return }
                if let proof {
                    let duplicate = try Bool.fetchOne(database, sql: """
                        SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_preservations AS saved
                          JOIN clipboard_sync_preserved_edits AS notice ON notice.local_entry_id = saved.id
                          WHERE saved.account_id = ? AND saved.epoch = ? AND saved.shared_id = ? AND saved.preserved_digest = ?)
                        """, arguments: [row["account_id"] as String, row["epoch"] as String, row["shared_id"] as String, proof.digest]) ?? false
                    if !duplicate { try Self.insertPreservedSyncFile(id: id, source: source, proof: proof, row: row, in: database) }
                }
                try database.execute(sql: "UPDATE clipboard_sync_file_preservations SET completed = 1, preserved_digest = ? WHERE id = ?", arguments: [proof?.digest, id])
                try Self.bumpHistoryRevision(in: database)
            }
            publishMutation()
        }
    }

    private func preparePreservedSyncFile(_ source: ClipboardSyncPreservedFileSource, destination: URL) async throws -> ClipboardLinkedFileProof? {
        if let frozen = source.frozen, let account = source.account, let control = source.control {
            guard let key = try await syncServices?.keys.load(account: account, keyID: control.keyID),
                  key.count == 32, ClipboardSyncCodec.check(key: key, account: account, keyID: control.keyID) == control.keyCheck else {
                throw ClipboardSyncServiceError.keyUnavailable
            }
            try await Self.verifySyncFileRestoration(frozen.descriptor, directory: frozen.uploadDirectory,
                account: account, control: control, key: key)
            let root = destination.deletingLastPathComponent()
            let candidate = try await ClipboardSyncFilePublication.construct(descriptor: frozen.descriptor,
                encryptedDirectory: frozen.uploadDirectory, root: root, account: account, control: control, key: key)
            defer { ClipboardSyncFilePublication.discard(candidate) }
            let output = try ClipboardSyncFilePublication.publish(candidate, descriptor: frozen.descriptor,
                root: root, accountID: account.identifier, faults: faultInjector)
            return try await Task.detached { try ClipboardLinkedFileIO.inspect(output.url, expectedIdentity: output.identity) }.value
        }
        return try await Task.detached(priority: .utility) {
            let proof = try ClipboardLinkedIdentityResolution.inspect(source.location)
            guard source.unpublished || proof.digest != source.location.baseDigest else { return nil as ClipboardLinkedFileProof? }
            return try ClipboardLinkedFileIO.preserveIndependent(proof, at: destination)
        }.value
    }

    private static func insertPreservedSyncFile(id: String, source: ClipboardSyncPreservedFileSource,
        proof: ClipboardLinkedFileProof, row: Row, in database: Database) throws {
        let name = proof.url.lastPathComponent
        try database.execute(sql: """
            INSERT INTO clipboard_sync_preserved_edits(account_id, epoch, shared_id, version_id, local_entry_id)
            VALUES (?, ?, ?, ?, ?);
            """, arguments: [row["account_id"] as String, row["epoch"] as String, row["shared_id"] as String,
                source.frozen?.descriptor.versionID.uuidString ?? source.location.id.uuidString, id])
        try database.execute(sql: """
            INSERT INTO clipboard_entries(id, captured_at, last_captured_at, source_bundle_id, source_display_name,
                source_provenance, preview_text, is_favorite) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, source.capturedAt, source.lastCapturedAt, source.sourceBundleID,
                source.sourceDisplayName, source.provenance, name, source.favorite])
        try database.execute(sql: "INSERT INTO clipboard_items(entry_id, item_index) VALUES (?, 0)", arguments: [id])
        try database.execute(sql: """
            INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, data_value)
            VALUES (?, 0, 0, 'fileReference', 'public.file-url', X'')
            """, arguments: [id])
        try database.execute(sql: """
            INSERT INTO clipboard_file_members(entry_id, item_index, member_index, captured_path, current_path,
                display_name, bookmark_data, resource_type, availability, identity_data)
            VALUES (?, 0, 0, ?, ?, ?, ?, 'file', 'available', ?)
            """, arguments: [id, proof.url.path, proof.url.path, name, proof.bookmark, proof.identity])
        try database.execute(sql: "INSERT INTO clipboard_entry_facets(entry_id, facet) VALUES (?, 'file')", arguments: [id])
        try database.execute(sql: "INSERT INTO clipboard_retention_state(entry_id, retention_started_at, is_protected) VALUES (?, ?, 1)", arguments: [id, source.lastCapturedAt])
        for tagID in source.tagIDs {
            try database.execute(sql: "INSERT INTO clipboard_entry_tags(entry_id, tag_id) SELECT ?, id FROM clipboard_tag_definitions WHERE id = ?", arguments: [id, tagID])
        }
        try insertSearchField(value: name, kind: "fileName", index: 0, rankingGroup: searchRankingGroup(for: "fileName"),
            entryID: id, into: database, faultInjector: .init())
    }
}

extension ClipboardLinkedFileIO {
    static func preserveIndependent(_ source: ClipboardLinkedFileProof, at destination: URL) throws -> ClipboardLinkedFileProof {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try inspect(destination)
            guard existing.digest == source.digest, existing.byteCount == source.byteCount else { throw ClipboardHistoryModuleError.operationUnavailable }
            return existing
        }
        try FileManager.default.copyItem(at: source.url, to: destination)
        let copy = try inspect(destination)
        guard source.stamp.matches(source.url), copy.digest == source.digest, copy.byteCount == source.byteCount else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return copy
    }
}
