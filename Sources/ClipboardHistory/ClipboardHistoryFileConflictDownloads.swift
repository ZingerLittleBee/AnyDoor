import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func requestFileConflictDownload(_ plan: ClipboardHistoryFileConflictPlan, versionID: UUID) async throws {
        try await waitForWriteTurn()
        try admitSync(syncGeneration)
        try syncWrite { database in
            guard let data = try Data.fetchOne(database, sql: "SELECT snapshot FROM clipboard_sync_file_conflict_plans WHERE id = ?", arguments: [plan.id.uuidString]) else {
                throw ClipboardHistoryFileConflictError.stalePlan
            }
            let snapshot = try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: data)
            let basis = try fileConflictBasis(entryID: .init(snapshot.entryID), objectID: snapshot.objectID, in: database)
            try Self.validateConflictBasis(basis, snapshot: snapshot)
            guard snapshot.heads.contains(versionID), let version = basis.versions.first(where: { $0.descriptor.versionID == versionID }),
                  version.descriptor.state == .available else { throw ClipboardHistoryFileConflictError.candidateUnavailable }
            try validateSyncFileDescriptor(version.descriptor, epoch: snapshot.epoch, keyID: snapshot.keyID)
            try Self.pinFileConflictVersion(versionID, planID: plan.id, snapshot: snapshot, in: database)
            try database.execute(sql: "UPDATE clipboard_sync_file_conflict_pins SET download_requested = 1 WHERE plan_id = ? AND version_id = ?",
                arguments: [plan.id.uuidString, versionID.uuidString])
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_downloads(account_id, epoch, object_id, version_id, authorized)
                VALUES (?, ?, ?, ?, 1) ON CONFLICT(account_id, epoch, object_id, version_id) DO UPDATE SET authorized = 1, failure = NULL
                """, arguments: [snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString, versionID.uuidString])
            // A previously complete URL may now be a dirty linked working file.
            // The explicitly requested immutable version is reconstructed apart.
            try database.execute(sql: """
                UPDATE clipboard_sync_file_versions SET transfer_state = 'pending'
                WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                """, arguments: [snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString, versionID.uuidString])
        }
        await retrySync()
    }

    static let pinnedFileConflictDownload = """
        EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins AS pin
          WHERE pin.account_id = version.account_id AND pin.epoch = version.epoch
            AND pin.object_id = version.object_id AND pin.version_id = version.version_id AND pin.download_requested = 1)
        """

    func isFileConflictDownload(_ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID) throws -> Bool {
        try linkedRead { database in
            try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins
                  WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ? AND download_requested = 1)
                """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString]) ?? false
        }
    }

    func syncFilePublicationRoot(_ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID) throws -> URL {
        try isFileConflictDownload(descriptor, account: account, epoch: epoch)
            ? syncWorkingRoot.appendingPathComponent("Conflict Versions", isDirectory: true) : syncWorkingRoot
    }
}
