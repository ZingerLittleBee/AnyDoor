import Foundation
import GRDB

extension ClipboardHistoryModule {
    static func rememberSyncContentRecord(_ record: ClipboardSyncRemoteRecord, subjectID: String,
                                          accountID: String, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_subject_records(account_id, epoch, shared_id, record_id, metadata)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(account_id, epoch, record_id) DO UPDATE SET purged = 0
            """, arguments: [accountID, record.epoch.uuidString, subjectID, record.recordID, try JSONEncoder().encode(record)])
    }

    /// Also reconstructs receipt metadata for stores that shared content before
    /// the deletion journal existed. No encrypted asset is downloaded here.
    func rememberDiscoveredSyncRecord(_ record: ClipboardSyncRemoteRecord, account: ClipboardSyncAccount) throws {
        try syncWrite { database in
            guard let subject = try String.fetchOne(database, sql: """
                SELECT shared_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND record_id = ?
                UNION SELECT subject_id FROM clipboard_sync_versions WHERE account_id = ? AND epoch = ? AND record_id = ?
                LIMIT 1
                """, arguments: [account.identifier, record.epoch.uuidString, record.recordID,
                    account.identifier, record.epoch.uuidString, record.recordID]) else { return }
            try Self.rememberSyncContentRecord(record, subjectID: subject, accountID: account.identifier, in: database)
        }
    }

    func nextDeletedSyncContent(account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncRemoteRecord? {
        try requiredDatabase().read { database in
            let data = try Data.fetchOne(database, sql: """
                SELECT content.metadata FROM clipboard_sync_subject_records AS content
                JOIN clipboard_sync_deletions AS deleted ON deleted.account_id = content.account_id
                    AND deleted.epoch = content.epoch AND deleted.shared_id = content.shared_id
                WHERE content.account_id = ? AND content.epoch = ? AND content.purged = 0
                  AND (deleted.origin = 'remote' OR EXISTS (SELECT 1 FROM clipboard_sync_outbox AS deletion
                    WHERE deletion.record_id = deleted.record_id AND deletion.acknowledged = 1))
                ORDER BY content.record_id LIMIT 1
                """, arguments: [account.identifier, control.epoch.uuidString])
            return try data.map { try JSONDecoder().decode(ClipboardSyncRemoteRecord.self, from: $0) }
        }
    }
}
