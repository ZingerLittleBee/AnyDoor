import Foundation
import GRDB

extension ClipboardHistoryModule {
    static func createSyncDownloadSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_uploads (
                record_id TEXT PRIMARY KEY NOT NULL REFERENCES clipboard_sync_outbox(record_id) ON DELETE CASCADE,
                directory TEXT NOT NULL, completed_bytes INTEGER NOT NULL DEFAULT 0
            );
            """)
    }

    func storeSyncFileUpload(_ upload: ClipboardSyncFileUpload, objectID: UUID,
        account: ClipboardSyncAccount, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_outbox(record_id, account_id, epoch, subject_id, kind, metadata)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [upload.record.recordID, account.identifier, upload.record.epoch.uuidString,
                objectID.uuidString, upload.record.kind.rawValue, try JSONEncoder().encode(upload.record)])
        try database.execute(sql: "INSERT INTO clipboard_sync_file_uploads(record_id, directory) VALUES (?, ?)",
            arguments: [upload.record.recordID, upload.directory.path])
    }

    func recordSyncFileUploadProgress(_ bytes: Int64, record: ClipboardSyncRemoteRecord,
        generation: UInt64) async throws {
        try await waitForWriteTurn()
        try admitSync(generation)
        try syncWrite { database in
            try database.execute(sql: "UPDATE clipboard_sync_file_uploads SET completed_bytes = ? WHERE record_id = ?",
                arguments: [bytes, record.recordID])
        }
    }
}
