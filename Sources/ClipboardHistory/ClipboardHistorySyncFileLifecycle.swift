import Foundation
import GRDB

extension ClipboardHistoryModule {
    static func createSyncFileLifecycleSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_subjects (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, object_id TEXT NOT NULL, shared_id TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, object_id, shared_id)
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_file_records (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, record_id TEXT NOT NULL, object_id TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, record_id)
            ) WITHOUT ROWID;
            """)
        for row in try Row.fetchAll(database, sql: "SELECT account_id, epoch, shared_id FROM clipboard_sync_entries") {
            try rememberSyncFileOwnership(sharedID: row["shared_id"], accountID: row["account_id"], epoch: row["epoch"], in: database)
        }
    }

    /// Keep the object-to-entry relationship independently of cascading members.
    /// It resolves existing shared lifecycle authority; it is not another tombstone.
    static func rememberSyncFileOwnership(sharedID: String, accountID: String, epoch: String, in database: Database) throws {
        try database.execute(sql: """
            INSERT OR IGNORE INTO clipboard_sync_file_subjects(account_id, epoch, object_id, shared_id)
            SELECT member.account_id, member.epoch, member.object_id, shared.shared_id
            FROM clipboard_sync_file_members AS member JOIN clipboard_sync_entries AS shared
              ON shared.account_id = member.account_id AND shared.epoch = member.epoch AND shared.local_entry_id = member.entry_id
            WHERE shared.account_id = ? AND shared.epoch = ? AND shared.shared_id = ?
            """, arguments: [accountID, epoch, sharedID])
        let objects = try String.fetchAll(database, sql: """
            SELECT object_id FROM clipboard_sync_file_subjects WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [accountID, epoch, sharedID])
        for objectID in objects {
            for data in try Data.fetchAll(database, sql: """
                SELECT descriptor FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [accountID, epoch, objectID]) {
                let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: data)
                if let body = descriptor.body {
                    try rememberSyncFileRecord(body, objectID: objectID, sharedID: sharedID, accountID: accountID, in: database)
                }
            }
            // Includes pending segments whose manifest never reached the provider,
            // acknowledged bodies, and immutable version-publication envelopes.
            for data in try Data.fetchAll(database, sql: """
                SELECT metadata FROM clipboard_sync_outbox
                WHERE account_id = ? AND epoch = ? AND subject_id = ?
                """, arguments: [accountID, epoch, objectID]) {
                try rememberSyncFileRecord(JSONDecoder().decode(ClipboardSyncRemoteRecord.self, from: data),
                    objectID: objectID, sharedID: sharedID, accountID: accountID, in: database)
            }
        }
    }

    static func rememberSyncFileRecord(_ record: ClipboardSyncRemoteRecord, objectID: String,
        sharedID: String, accountID: String, in database: Database) throws {
        try database.execute(sql: """
            INSERT OR IGNORE INTO clipboard_sync_file_records(account_id, epoch, record_id, object_id) VALUES (?, ?, ?, ?)
            """, arguments: [accountID, record.epoch.uuidString, record.recordID, objectID])
        // Older version events were recorded under their object subject. Bridge
        // those rows to the entry authority before asking the common purge queue.
        try database.execute(sql: """
            UPDATE clipboard_sync_subject_records SET shared_id = ?
            WHERE account_id = ? AND epoch = ? AND record_id = ? AND shared_id = ?
            """, arguments: [sharedID, accountID, record.epoch.uuidString, record.recordID, objectID])
        try rememberSyncContentRecord(record, subjectID: sharedID, accountID: accountID, in: database)
    }

    static func syncFileRecordHasLiveOwner(accountID: String) -> SQL {
        """
        EXISTS (SELECT 1 FROM clipboard_sync_file_records AS file
          JOIN clipboard_sync_file_members AS member ON member.account_id = file.account_id
            AND member.epoch = file.epoch AND member.object_id = file.object_id
          JOIN clipboard_entries AS entry ON entry.id = member.entry_id
          WHERE file.account_id = content.account_id AND file.epoch = content.epoch AND file.record_id = content.record_id
            AND (\(syncEntryPublicationAuthority(accountID: accountID))))
        """
    }
}
