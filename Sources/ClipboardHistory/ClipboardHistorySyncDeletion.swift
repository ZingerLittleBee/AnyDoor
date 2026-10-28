import Foundation
import GRDB

struct ClipboardSyncDeletion: Codable, Equatable, Sendable {
    let sharedID: String
}

public struct ClipboardHistoryPreservedEdit: Equatable, Sendable, Identifiable {
    public let id: ClipboardHistoryEntryID
    public let previewText: String
}

extension ClipboardHistoryModule {
    static func createSyncDeletionSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_deletions (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, shared_id TEXT NOT NULL,
                record_id TEXT, origin TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, shared_id)
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_subject_records (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, shared_id TEXT NOT NULL,
                record_id TEXT NOT NULL, metadata BLOB NOT NULL, purged INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(account_id, epoch, record_id)
            ) WITHOUT ROWID;
            INSERT INTO clipboard_sync_subject_records(account_id, epoch, shared_id, record_id, metadata)
                SELECT account_id, epoch, subject_id, record_id, metadata FROM clipboard_sync_outbox WHERE kind = 'entry';
            CREATE TABLE clipboard_sync_preserved_edits (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, shared_id TEXT NOT NULL, version_id TEXT NOT NULL,
                local_entry_id TEXT NOT NULL UNIQUE, dismissed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(account_id, epoch, shared_id, version_id)
            ) WITHOUT ROWID;
            """)
        for row in try Row.fetchAll(database, sql: "SELECT id, state FROM clipboard_sync_accounts") {
            let data: Data = row["state"]
            var state = try JSONDecoder().decode(ClipboardSyncAccountState.self, from: data)
            state.cursor = nil
            try database.execute(sql: "UPDATE clipboard_sync_accounts SET state = ? WHERE id = ?",
                arguments: [try JSONEncoder().encode(state), row["id"] as String])
        }
    }

    static func isSyncDeleted(_ sharedID: String, accountID: String, epoch: String, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT EXISTS (SELECT 1 FROM clipboard_sync_deletions WHERE account_id = ? AND epoch = ? AND shared_id = ?)
            """, arguments: [accountID, epoch, sharedID]) ?? false
    }

    static func syncDeletionScope(entryIDs: [String], in database: Database) throws -> [String] {
        var identities = Set<String>()
        for id in entryIDs {
            for row in try Row.fetchAll(database, sql: """
                SELECT account_id, epoch, shared_id FROM clipboard_sync_entries AS shared WHERE local_entry_id = ?
                  AND NOT EXISTS (SELECT 1 FROM clipboard_sync_deletions AS deleted
                    WHERE deleted.account_id = shared.account_id AND deleted.epoch = shared.epoch AND deleted.shared_id = shared.shared_id)
                """, arguments: [id]) {
                let fields: [String] = [row["account_id"], row["epoch"], row["shared_id"]]
                identities.insert(fields.joined(separator: "/"))
            }
        }
        return identities.sorted()
    }

    static func sharedDeletionCount(entryIDs: [String], in database: Database) throws -> Int {
        try entryIDs.reduce(0) { count, id in
            let shared = try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_entries AS shared WHERE local_entry_id = ?
                    AND NOT EXISTS (SELECT 1 FROM clipboard_sync_deletions AS deleted
                        WHERE deleted.account_id = shared.account_id AND deleted.epoch = shared.epoch AND deleted.shared_id = shared.shared_id))
                """, arguments: [id]) ?? false
            return count + (shared ? 1 : 0)
        }
    }

    static func recordExplicitSyncDeletion(entryIDs: [String], in database: Database) throws {
        for localID in entryIDs {
            for row in try Row.fetchAll(database, sql: "SELECT account_id, epoch, shared_id FROM clipboard_sync_entries WHERE local_entry_id = ?",
                arguments: [localID]) {
                try recordSyncDeletion(row["shared_id"], accountID: row["account_id"], epoch: row["epoch"],
                    recordID: nil, origin: "local", in: database)
            }
        }
    }

    static func recordSyncDeletion(_ sharedID: String, accountID: String, epoch: String, recordID: String?,
                                   origin: String, in database: Database) throws {
        guard UUID(uuidString: sharedID) != nil else { throw ClipboardSyncServiceError.corruptData }
        guard try !isSyncDeleted(sharedID, accountID: accountID, epoch: epoch, in: database) else { return }
        try rememberSyncFileOwnership(sharedID: sharedID, accountID: accountID, epoch: epoch, in: database)
        try captureSyncFileCleanup(sharedID: sharedID, accountID: accountID, epoch: epoch, in: database)
        try database.execute(sql: """
            INSERT INTO clipboard_sync_deletions(account_id, epoch, shared_id, record_id, origin) VALUES (?, ?, ?, ?, ?)
            """, arguments: [accountID, epoch, sharedID, recordID, origin])
        try database.execute(sql: "DELETE FROM clipboard_sync_outbox WHERE account_id = ? AND epoch = ? AND subject_id = ?",
            arguments: [accountID, epoch, sharedID])
        try database.execute(sql: "UPDATE clipboard_sync_memberships SET pending = 0 WHERE account_id = ? AND epoch = ? AND shared_id = ?",
            arguments: [accountID, epoch, sharedID])
    }

    func stageSyncDeletions(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, in database: Database) throws {
        for row in try Row.fetchAll(database, sql: """
            SELECT shared_id FROM clipboard_sync_deletions WHERE account_id = ? AND epoch = ? AND origin = 'local' AND record_id IS NULL
            """, arguments: [account.identifier, control.epoch.uuidString]) {
            let sharedID: String = row["shared_id"]
            let upload = try ClipboardSyncCodec.seal(.deletion(.init(sharedID: sharedID)), account: account, control: control, key: key)
            try storeSyncUpload(upload, subjectID: sharedID, account: account, in: database)
            try database.execute(sql: "UPDATE clipboard_sync_deletions SET record_id = ? WHERE account_id = ? AND epoch = ? AND shared_id = ?",
                arguments: [upload.record.recordID, account.identifier, control.epoch.uuidString, sharedID])
        }
    }

    func receiveSyncDeletion(_ deletion: ClipboardSyncDeletion, record: ClipboardSyncRemoteRecord,
                             account: ClipboardSyncAccount, in database: Database) throws {
        if try !Self.isSyncDeleted(deletion.sharedID, accountID: account.identifier, epoch: record.epoch.uuidString, in: database) {
            try Self.captureSyncFilePreservations(sharedID: deletion.sharedID, accountID: account.identifier, epoch: record.epoch.uuidString, in: database)
            try preserveUnuploadedSyncEdits(sharedID: deletion.sharedID, accountID: account.identifier,
                epoch: record.epoch.uuidString, in: database)
        }
        try Self.recordSyncDeletion(deletion.sharedID, accountID: account.identifier, epoch: record.epoch.uuidString,
            recordID: record.recordID, origin: "remote", in: database)
        let ids = try String.fetchAll(database, sql: """
            SELECT local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [account.identifier, record.epoch.uuidString, deletion.sharedID])
        // Encrypted payload orphans are reclaimed by normal maintenance; user files are never removed.
        _ = try logicallyDelete(entryIDs: ids, in: database)
    }

    public func preservedSyncEdits() async throws -> [ClipboardHistoryPreservedEdit] {
        try await resumeSyncFilePreservations()
        return try linkedRead { database in
            try Row.fetchAll(database, sql: """
                SELECT entry.id, entry.preview_text FROM clipboard_sync_preserved_edits AS saved
                JOIN clipboard_entries AS entry ON entry.id = saved.local_entry_id
                WHERE saved.dismissed = 0 ORDER BY entry.last_captured_at DESC, entry.id
                """).map { row in
                    let value: String = row["id"]
                    guard let id = UUID(uuidString: value) else { throw ClipboardSyncServiceError.corruptData }
                    return ClipboardHistoryPreservedEdit(id: .init(id), previewText: row["preview_text"])
                }
        }
    }

    public func dismissPreservedSyncEdits(_ ids: [ClipboardHistoryEntryID]) async throws {
        let pool = try await writableDatabase()
        try await pool.write { database in
            for id in ids {
                try database.execute(sql: "UPDATE clipboard_sync_preserved_edits SET dismissed = 1 WHERE local_entry_id = ?",
                    arguments: [id.value.uuidString.lowercased()])
            }
        }
        publishMutation()
    }

    private func preserveUnuploadedSyncEdits(sharedID: String, accountID: String, epoch: String, in database: Database) throws {
        guard let originalID = try String.fetchOne(database, sql: """
            SELECT shared.local_entry_id FROM clipboard_sync_entries AS shared
            JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            WHERE shared.account_id = ? AND shared.epoch = ? AND shared.shared_id = ?
            """, arguments: [accountID, epoch, sharedID]) else { return }
        let pending = try Row.fetchAll(database, sql: """
            SELECT version.version_id, version.content FROM clipboard_sync_versions AS version
            LEFT JOIN clipboard_sync_outbox AS upload ON upload.record_id = version.record_id
            WHERE version.account_id = ? AND version.epoch = ? AND version.subject_id = ? AND version.origin = 'local'
              AND (version.record_id IS NULL OR upload.acknowledged = 0)
            """, arguments: [accountID, epoch, sharedID])
        let edits = try pending.map { row -> ClipboardSyncTextEditContent in
            let data: Data = row["content"]
            return try JSONDecoder().decode(ClipboardSyncTextEditContent.self, from: data)
        }
        let nodes = try Self.syncVersionNodes(subjectID: sharedID, accountID: accountID, epoch: epoch, in: database)
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parents) })
        var ancestors = Set<UUID>()
        func addAncestors(_ id: UUID) {
            for parent in byID[id] ?? [] where ancestors.insert(parent).inserted { addAncestors(parent) }
        }
        for edit in edits { addAncestors(edit.versionID) }
        for edit in edits where !ancestors.contains(edit.versionID) {
            let localID = UUID().uuidString.lowercased()
            try database.execute(sql: """
                INSERT INTO clipboard_sync_preserved_edits(account_id, epoch, shared_id, version_id, local_entry_id)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [accountID, epoch, sharedID, edit.versionID.uuidString, localID])
            try database.execute(sql: """
                INSERT INTO clipboard_entries(id, captured_at, last_captured_at, source_bundle_id, source_display_name,
                    source_provenance, preview_text, is_favorite)
                SELECT ?, captured_at, last_captured_at, source_bundle_id, source_display_name, source_provenance, ?, is_favorite
                FROM clipboard_entries WHERE id = ?
                """, arguments: [localID, Self.boundedPreviewText(edit.text), originalID])
            try database.execute(sql: "INSERT INTO clipboard_items(entry_id, item_index) VALUES (?, 0)", arguments: [localID])
            try database.execute(sql: """
                INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, text_value)
                VALUES (?, 0, 0, 'text', 'public.utf8-plain-text', ?)
                """, arguments: [localID, edit.text])
            try database.execute(sql: "INSERT INTO clipboard_entry_facets(entry_id, facet) VALUES (?, 'text')", arguments: [localID])
            try database.execute(sql: "INSERT INTO clipboard_entry_tags(entry_id, tag_id) SELECT ?, tag_id FROM clipboard_entry_tags WHERE entry_id = ?",
                arguments: [localID, originalID])
            try database.execute(sql: """
                INSERT INTO clipboard_retention_state(entry_id, retention_started_at, is_protected)
                SELECT ?, retention_started_at, is_protected FROM clipboard_retention_state WHERE entry_id = ?
                """, arguments: [localID, originalID])
            try Self.insertSearchField(value: edit.text, kind: "exactText", index: 0,
                rankingGroup: Self.searchRankingGroup(for: "exactText"), entryID: localID, into: database, faultInjector: faultInjector)
        }
    }
}

extension ClipboardSyncContent {
    var entrySubjectID: String? {
        switch self {
        case .rejoin(let value): value.state.sharedID
        case .text(let value): value.id.uuidString.lowercased()
        case .textEdit(let value): value.id.uuidString.lowercased()
        case .entry(let value): value.id.uuidString.lowercased()
        case .tagMembership(let value): value.sharedID
        case .metadata(let value): value.id.uuidString.lowercased()
        case .deletion, .withdrawal, .tag, .tagState, .tagMerge, .fileBody, .fileVersion: nil
        }
    }
}
