import Foundation
import GRDB
import Darwin

extension ClipboardHistoryModule {
    static func createSyncFileCleanupSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_cleanup (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, object_id TEXT NOT NULL, version_id TEXT NOT NULL,
                retired INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(account_id, epoch, object_id, version_id)
            ) WITHOUT ROWID;
            """)
    }

    /// Capture only transfer ownership. Visible working files, originals, and
    /// replacement backups are never cache-cleanup targets.
    static func captureSyncFileCleanup(sharedID: String, accountID: String, epoch: String,
        retired: Bool = false, in database: Database) throws {
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
                try database.execute(sql: """
                    INSERT INTO clipboard_sync_file_cleanup(account_id, epoch, object_id, version_id, retired) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, epoch, object_id, version_id) DO UPDATE SET retired = MAX(retired, excluded.retired)
                    """, arguments: [accountID, epoch, object, version, retired])
            }
        }
    }

    func reclaimDeletedSyncFileTransfers() async throws {
        let store = storeEpoch
        let root = storeRoot.appendingPathComponent("SyncTransfers", isDirectory: true)
        let faults = faultInjector
        let rows = try linkedRead { database in
            try Row.fetchAll(database, sql: """
                SELECT cleanup.* FROM clipboard_sync_file_cleanup AS cleanup
                WHERE (cleanup.retired = 1 OR NOT EXISTS (SELECT 1 FROM clipboard_sync_file_subjects AS owner
                  WHERE owner.account_id = cleanup.account_id AND owner.epoch = cleanup.epoch AND owner.object_id = cleanup.object_id
                    AND NOT EXISTS (SELECT 1 FROM clipboard_sync_deletions AS deleted
                      WHERE deleted.account_id = owner.account_id AND deleted.epoch = owner.epoch AND deleted.shared_id = owner.shared_id)))
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
                    for url in urls { try Self.removeOwnedSyncTransfer(url, root: root, faults: faults) }
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
                try database.execute(sql: "DELETE FROM clipboard_sync_file_retries WHERE account_id = ? AND epoch = ? AND work_id = ?",
                    arguments: [account, epoch, "download/\(version)"])
                try database.execute(sql: """
                    DELETE FROM clipboard_sync_file_retries WHERE account_id = ? AND epoch = ?
                      AND work_id IN (SELECT 'location/' || id FROM clipboard_sync_linked_locations
                        WHERE account_id = ? AND epoch = ? AND object_id = ?)
                    """, arguments: [account, epoch, account, epoch, object])
                try database.execute(sql: "DELETE FROM clipboard_sync_outbox WHERE account_id = ? AND epoch = ? AND subject_id = ?",
                    arguments: [account, epoch, object])
            }
        }
    }

    nonisolated private static func removeOwnedSyncTransfer(_ url: URL, root: URL, faults: ClipboardHistoryFaultInjector) throws {
        let store = root.deletingLastPathComponent()
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw ClipboardHistoryStorageError.unsafePayloadPath
        }
        let components = url.pathComponents.dropFirst(store.pathComponents.count)
        guard let name = components.last else { throw ClipboardHistoryStorageError.unsafePayloadPath }
        var parent = open(store.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(parent) }
        for component in components.dropLast() {
            let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if child < 0, errno == ENOENT { return }
            guard child >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
            close(parent); parent = child
        }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if directory < 0, errno == ENOENT { return }
        guard directory >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        defer { close(directory) }
        var identity = stat()
        guard fstat(directory, &identity) == 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        try faults.check(.syncFileCleanupBeforeRemoval)
        let enumeration = dup(directory)
        guard enumeration >= 0 else { throw ClipboardHistoryStorageError.fileOperationFailed(errno) }
        guard let stream = fdopendir(enumeration) else {
            close(enumeration); throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        defer { closedir(stream) }
        while let item = readdir(stream) {
            let leaf = withUnsafeBytes(of: item.pointee.d_name) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
            guard let leaf, ClipboardSyncFileIO.validFilename(leaf) else {
                if leaf == "." || leaf == ".." { continue }
                throw ClipboardHistoryStorageError.unsafePayloadPath
            }
            var status = stat()
            if fstatat(directory, leaf, &status, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT { continue }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ClipboardHistoryStorageError.unsafePayloadPath }
            guard unlinkat(directory, leaf, 0) == 0 || errno == ENOENT else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
        }
        var current = stat()
        if fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT { return }
        guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            throw ClipboardHistoryStorageError.unsafePayloadPath
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }
}
