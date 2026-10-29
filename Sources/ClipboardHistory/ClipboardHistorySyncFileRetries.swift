import Foundation
import GRDB

enum ClipboardSyncFileWork: Sendable {
    case download(UUID)
    case linkedLocation(UUID)

    var identifier: String {
        switch self {
        case .download(let version): "download/\(version.uuidString)"
        case .linkedLocation(let location): "location/\(location.uuidString)"
        }
    }
}

extension ClipboardHistoryModule {
    static func createSyncFileRetrySchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_retries (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, work_id TEXT NOT NULL,
                phase BLOB NOT NULL, retry_not_before REAL NOT NULL,
                PRIMARY KEY(account_id, epoch, work_id)
            ) WITHOUT ROWID;
            """)
    }

    /// Only errors attributable to one file may defer its work. Account, key,
    /// control, provider backoff, and database failures retain pass-wide authority.
    static func isIsolatedSyncFileFailure(_ error: Error) -> Bool {
        if ClipboardSyncFileErrors.isAccessDenied(error) || ClipboardSyncFileErrors.isSourceChanged(error) { return true }
        switch error as? ClipboardSyncServiceError {
        case .recordUnavailable, .corruptData, .localFileAccessDenied: return true
        default: return false
        }
    }

    func shouldDeferSyncFileWork(_ work: ClipboardSyncFileWork, account: ClipboardSyncAccount,
        control: ClipboardSyncControl) throws -> Bool {
        guard let row = try syncFileRead({ try Row.fetchOne($0, sql: """
            SELECT phase, retry_not_before FROM clipboard_sync_file_retries
            WHERE account_id = ? AND epoch = ? AND work_id = ?
            """, arguments: [account.identifier, control.epoch.uuidString, work.identifier]) }),
              (row["retry_not_before"] as Double) > now().timeIntervalSince1970 else { return false }
        let phase = try JSONDecoder().decode(ClipboardHistorySyncPhase.self, from: row["phase"])
        if deferredSyncFileFailure == nil { deferredSyncFileFailure = phase }
        return true
    }

    func deferSyncFileWork(_ work: ClipboardSyncFileWork, error: Error, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, generation: UInt64) throws {
        try admitSync(generation)
        let phase = syncFailurePhase(error)
        try syncWrite { database in
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_retries(account_id, epoch, work_id, phase, retry_not_before)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, epoch, work_id) DO UPDATE SET
                    phase = excluded.phase, retry_not_before = excluded.retry_not_before
                """, arguments: [account.identifier, control.epoch.uuidString, work.identifier,
                    try JSONEncoder().encode(phase), now().addingTimeInterval(30).timeIntervalSince1970])
        }
        if deferredSyncFileFailure == nil { deferredSyncFileFailure = phase }
    }

    func completeSyncFileWork(_ work: ClipboardSyncFileWork, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, in database: Database) throws {
        try database.execute(sql: "DELETE FROM clipboard_sync_file_retries WHERE account_id = ? AND epoch = ? AND work_id = ?",
            arguments: [account.identifier, control.epoch.uuidString, work.identifier])
    }

    static func linkedSyncFileFailure(objectID: UUID, accountID: String, epoch: String,
        in database: Database) throws -> ClipboardHistorySyncFileFailure? {
        guard let data = try Data.fetchOne(database, sql: """
            SELECT retry.phase FROM clipboard_sync_file_retries AS retry
            JOIN clipboard_sync_linked_locations AS location
              ON retry.account_id = location.account_id AND retry.epoch = location.epoch
                AND retry.work_id = 'location/' || location.id
            WHERE location.account_id = ? AND location.epoch = ? AND location.object_id = ?
            ORDER BY location.id LIMIT 1
            """, arguments: [accountID, epoch, objectID.uuidString]) else { return nil }
        switch try JSONDecoder().decode(ClipboardHistorySyncPhase.self, from: data) {
        case .failed(let failure): return ClipboardHistorySyncFileFailure(rawValue: failure.rawValue) ?? .unavailable
        default: return .unavailable
        }
    }
}
