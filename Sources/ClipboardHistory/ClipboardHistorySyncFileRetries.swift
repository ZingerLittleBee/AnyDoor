import Foundation
import GRDB

enum ClipboardSyncFileWork: Sendable {
    case content(UUID)
    case download(UUID)
    case linkedLocation(UUID)
    case source(UUID)

    var identifier: String {
        switch self {
        case .content(let operation): "content/\(operation.uuidString)"
        case .download(let version): "download/\(version.uuidString)"
        case .linkedLocation(let location): "location/\(location.uuidString)"
        case .source(let object): "source/\(object.uuidString)"
        }
    }
}

private struct ClipboardSyncFileRetryFailure: Codable {
    let phase: ClipboardHistorySyncPhase
    let recordUnavailable: Bool
    let failureCount: Int

    init(phase: ClipboardHistorySyncPhase, recordUnavailable: Bool, failureCount: Int = 1) {
        self.phase = phase
        self.recordUnavailable = recordUnavailable
        self.failureCount = failureCount
    }

    private enum CodingKeys: String, CodingKey { case phase, recordUnavailable, failureCount }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.phase) {
            phase = try container.decode(ClipboardHistorySyncPhase.self, forKey: .phase)
            recordUnavailable = try container.decode(Bool.self, forKey: .recordUnavailable)
            failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 1
            guard failureCount > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .failureCount, in: container,
                    debugDescription: "A retry must retain at least one failure")
            }
        } else {
            // Legacy rows have only a display phase, which does not prove the
            // original error. Keep reporting them until the existing retry is due.
            phase = try ClipboardHistorySyncPhase(from: decoder)
            recordUnavailable = false
            failureCount = 1
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
        if error is ClipboardSyncFileCacheFailure { return true }
        if error is ClipboardWorkingOutputRecoveryRequired { return true }
        if ClipboardSyncFileErrors.isAccessDenied(error) || ClipboardSyncFileErrors.isSourceChanged(error)
            || ClipboardSyncFileErrors.isLocalOperationFailure(error) { return true }
        switch error as? ClipboardSyncServiceError {
        case .recordUnavailable, .corruptData, .localFileAccessDenied: return true
        default: return false
        }
    }

    /// Source publication also reads keys and stored metadata. Only identified
    /// native source/cache failures are local to that publication attempt.
    static func isIsolatedSyncSourceFailure(_ error: Error) -> Bool {
        error is ClipboardSyncFileCacheFailure
            || ClipboardSyncFileErrors.isAccessDenied(error) || ClipboardSyncFileErrors.isSourceChanged(error)
            || ClipboardSyncFileErrors.isLocalOperationFailure(error)
            || (error as? ClipboardSyncServiceError) == .localFileAccessDenied
    }

    func shouldDeferSyncFileWork(_ work: ClipboardSyncFileWork, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, reportMissingRecord: Bool = true) throws -> Bool {
        guard let row = try syncFileRead({ try Row.fetchOne($0, sql: """
            SELECT phase, retry_not_before FROM clipboard_sync_file_retries
            WHERE account_id = ? AND epoch = ? AND work_id = ?
            """, arguments: [account.identifier, control.epoch.uuidString, work.identifier]) }),
              (row["retry_not_before"] as Double) > now().timeIntervalSince1970 else { return false }
        let failure = try JSONDecoder().decode(ClipboardSyncFileRetryFailure.self, from: row["phase"])
        if deferredSyncFileFailure == nil, reportMissingRecord || !failure.recordUnavailable {
            deferredSyncFileFailure = failure.phase
        }
        return true
    }

    func deferSyncFileWork(_ work: ClipboardSyncFileWork, error: Error, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, generation: UInt64, reportMissingRecord: Bool = true) throws {
        try admitSync(generation)
        let phase = syncFailurePhase(error)
        let recordUnavailable = (error as? ClipboardSyncServiceError) == .recordUnavailable
        try syncWrite { database in
            var failureCount = 1
            if case .content = work, (error as? ClipboardSyncServiceError) == .corruptData,
               let previous = try Data.fetchOne(database, sql: """
                   SELECT phase FROM clipboard_sync_file_retries
                   WHERE account_id = ? AND epoch = ? AND work_id = ?
                   """, arguments: [account.identifier, control.epoch.uuidString, work.identifier]) {
                let retained = try JSONDecoder().decode(ClipboardSyncFileRetryFailure.self, from: previous)
                failureCount = min(retained.failureCount, 5) + 1
            }
            // Content may hide retirement authority. Keep discovering changes,
            // but retry an unchanged broken body less often across normal polls.
            let delay: TimeInterval = [30, 60, 120, 240, 480, 900][failureCount - 1]
            let failure = ClipboardSyncFileRetryFailure(phase: phase,
                recordUnavailable: recordUnavailable, failureCount: failureCount)
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_retries(account_id, epoch, work_id, phase, retry_not_before)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, epoch, work_id) DO UPDATE SET
                    phase = excluded.phase, retry_not_before = excluded.retry_not_before
                """, arguments: [account.identifier, control.epoch.uuidString, work.identifier,
                    try JSONEncoder().encode(failure), now().addingTimeInterval(delay).timeIntervalSince1970])
        }
        if deferredSyncFileFailure == nil, reportMissingRecord || !recordUnavailable {
            deferredSyncFileFailure = phase
        }
    }

    func completeSyncFileWork(_ work: ClipboardSyncFileWork, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, in database: Database) throws {
        try database.execute(sql: "DELETE FROM clipboard_sync_file_retries WHERE account_id = ? AND epoch = ? AND work_id = ?",
            arguments: [account.identifier, control.epoch.uuidString, work.identifier])
    }

    static func completeLinkedSyncFileWork(_ locationID: UUID, in database: Database) throws {
        try database.execute(sql: """
            DELETE FROM clipboard_sync_file_retries AS retry
            WHERE retry.work_id = ? AND EXISTS (
                SELECT 1 FROM clipboard_sync_linked_locations AS location
                WHERE location.id = ? AND location.account_id = retry.account_id AND location.epoch = retry.epoch)
            """, arguments: [ClipboardSyncFileWork.linkedLocation(locationID).identifier, locationID.uuidString])
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
        switch try JSONDecoder().decode(ClipboardSyncFileRetryFailure.self, from: data).phase {
        case .failed(let failure): return ClipboardHistorySyncFileFailure(rawValue: failure.rawValue) ?? .unavailable
        default: return .unavailable
        }
    }
}
