import Foundation
import GRDB

extension ClipboardHistoryModule {
    static func createSyncFileCleanupSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_cleanup (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, object_id TEXT NOT NULL, version_id TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, object_id, version_id)
            ) WITHOUT ROWID;
            """)
    }

    /// Capture only transfer ownership. Visible working files, originals, and
    /// replacement backups are never cache-cleanup targets.
    static func captureSyncFileCleanup(sharedID: String, accountID: String, epoch: String, in database: Database) throws {
        let objects = try String.fetchAll(database, sql: """
            SELECT object_id FROM clipboard_sync_file_subjects WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [accountID, epoch, sharedID])
        for object in objects {
            var versions = Set(try String.fetchAll(database, sql: """
                SELECT version_id FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [accountID, epoch, object]))
            for data in try Data.fetchAll(database, sql: """
                SELECT journal FROM clipboard_sync_file_resolutions WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [accountID, epoch, object]) {
                let journal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: data)
                versions.formUnion(journal.branches.map { $0.versionID.uuidString })
                versions.formUnion(journal.prepared.map { $0.descriptor.versionID.uuidString })
                versions.insert(journal.resultID.uuidString)
            }
            for version in versions {
                try database.execute(sql: "INSERT OR IGNORE INTO clipboard_sync_file_cleanup VALUES (?, ?, ?, ?)",
                    arguments: [accountID, epoch, object, version])
            }
        }
    }

    func reclaimDeletedSyncFileTransfers() async throws {
        let store = storeEpoch
        let root = storeRoot.appendingPathComponent("SyncTransfers", isDirectory: true)
        let rows = try linkedRead { database in
            try Row.fetchAll(database, sql: """
                SELECT cleanup.* FROM clipboard_sync_file_cleanup AS cleanup
                WHERE NOT EXISTS (SELECT 1 FROM clipboard_sync_file_subjects AS owner
                  WHERE owner.account_id = cleanup.account_id AND owner.epoch = cleanup.epoch AND owner.object_id = cleanup.object_id
                    AND NOT EXISTS (SELECT 1 FROM clipboard_sync_deletions AS deleted
                      WHERE deleted.account_id = owner.account_id AND deleted.epoch = owner.epoch AND deleted.shared_id = owner.shared_id))
                  AND NOT EXISTS (SELECT 1 FROM clipboard_sync_file_preservations AS saved
                    JOIN clipboard_sync_file_subjects AS owner USING(account_id, epoch, shared_id)
                    WHERE owner.account_id = cleanup.account_id AND owner.epoch = cleanup.epoch AND owner.object_id = cleanup.object_id
                      AND saved.completed = 0)
                """)
        }
        for row in rows {
            let account: String = row["account_id"], epoch: String = row["epoch"]
            let object: String = row["object_id"], version: String = row["version_id"]
            guard UUID(uuidString: epoch) != nil, UUID(uuidString: version) != nil,
                  !account.isEmpty, account != ".", account != "..", !account.contains("/") else { continue }
            let urls = [root.appendingPathComponent("Uploads/\(version)"),
                root.appendingPathComponent("Downloads/\(account)/\(epoch)/\(version)")]
            do {
                try await Task.detached(priority: .utility) {
                    for url in urls { try Self.removeOwnedSyncTransfer(url, root: root) }
                }.value
            } catch { continue }
            try await waitForWriteTurn()
            guard store == storeEpoch else { throw ClipboardHistoryModuleError.operationUnavailable }
            try syncWrite { database in
                try database.execute(sql: "DELETE FROM clipboard_sync_file_cleanup WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?",
                    arguments: [account, epoch, object, version])
                for table in ["clipboard_sync_file_downloads", "clipboard_sync_file_auto_candidates", "clipboard_sync_file_conflict_pins"] {
                    try database.execute(sql: "DELETE FROM \(table) WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?",
                        arguments: [account, epoch, object, version])
                }
                try database.execute(sql: "DELETE FROM clipboard_sync_outbox WHERE account_id = ? AND epoch = ? AND subject_id = ?",
                    arguments: [account, epoch, object])
            }
        }
    }

    nonisolated private static func removeOwnedSyncTransfer(_ url: URL, root: URL) throws {
        // Reject a replaced/symlinked parent rather than following it outside
        // this store. Missing paths make interrupted reclamation idempotent.
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let expectedRoot = root.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent)
        let suffix = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
        guard canonicalRoot.path == expectedRoot.path, canonical.path == canonicalRoot.path + suffix else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
