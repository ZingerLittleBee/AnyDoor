import CryptoKit
import Foundation
import GRDB

extension ClipboardHistoryModule {
    static func createSyncDownloadSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_uploads (
                record_id TEXT PRIMARY KEY NOT NULL REFERENCES clipboard_sync_outbox(record_id) ON DELETE CASCADE,
                directory TEXT NOT NULL, completed_bytes INTEGER NOT NULL DEFAULT 0, failure TEXT
            );
            CREATE TABLE clipboard_sync_file_downloads (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, object_id TEXT NOT NULL, version_id TEXT NOT NULL,
                authorized INTEGER NOT NULL DEFAULT 0, completed_chunks INTEGER NOT NULL DEFAULT 0,
                completed_bytes INTEGER NOT NULL DEFAULT 0, failure BLOB,
                PRIMARY KEY(account_id, epoch, object_id, version_id)
            ) WITHOUT ROWID;
            ALTER TABLE clipboard_sync_file_versions ADD COLUMN parents BLOB NOT NULL DEFAULT X'5B5D';
            ALTER TABLE clipboard_sync_file_versions ADD COLUMN publication_record_id TEXT;
            CREATE TABLE clipboard_sync_file_selections (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, object_id TEXT NOT NULL,
                current_version_id TEXT NOT NULL, complete_version_id TEXT,
                PRIMARY KEY(account_id, epoch, object_id)
            ) WITHOUT ROWID;
            INSERT INTO clipboard_sync_file_selections
                SELECT account_id, epoch, object_id, version_id,
                       CASE WHEN transfer_state = 'complete' THEN version_id ELSE NULL END
                FROM clipboard_sync_file_versions;
            """)
    }

    public func requestSyncFileDownload(entryID: ClipboardHistoryEntryID, objectID: UUID, versionID: UUID) async throws {
        try await waitForWriteTurn()
        let generation = syncGeneration
        try admitSync(generation)
        try syncWrite { database in
            let settings = try syncSettings(in: database)
            guard settings.enabled, let accountID = settings.accountID,
                  let context = try syncFileContext(in: database), context.control.phase == "active",
                  let row = try Row.fetchOne(database, sql: """
                    SELECT member.epoch, version.descriptor FROM clipboard_sync_file_members AS member
                    JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                    JOIN clipboard_sync_file_versions AS version ON version.account_id = member.account_id
                      AND version.epoch = member.epoch AND version.object_id = member.object_id AND version.version_id = choice.current_version_id
                    JOIN clipboard_representations AS current ON current.entry_id = member.entry_id
                      AND current.item_index = member.item_index AND current.representation_index = member.representation_index
                    WHERE member.account_id = ? AND member.epoch = ? AND member.entry_id = ? AND member.object_id = ?
                      AND choice.current_version_id = ? AND current.kind = 'fileReference'
                    """, arguments: [accountID, context.control.epoch.uuidString, entryID.value.uuidString.lowercased(), objectID.uuidString, versionID.uuidString]) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"])
            guard descriptor.state == .available else { throw ClipboardHistoryModuleError.operationUnavailable }
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_downloads(account_id, epoch, object_id, version_id, authorized)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(account_id, epoch, object_id, version_id) DO UPDATE SET authorized = 1, failure = NULL
                """, arguments: [accountID, row["epoch"] as String, objectID.uuidString, versionID.uuidString])
        }
        await retrySync()
    }

    func syncFileDownloadAuthorized(_ descriptor: ClipboardSyncFileDescriptor,
        account: ClipboardSyncAccount, epoch: UUID) throws -> Bool {
        guard let size = descriptor.originalByteCount else { return false }
        if size <= Self.automaticSyncFileDownloadBytes { return true }
        return try requiredDatabase().read { database in
            try Bool.fetchOne(database, sql: """
                SELECT authorized FROM clipboard_sync_file_downloads
                WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString]) ?? false
        }
    }

    func receiveSegmentedSyncFile(_ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, key: Data, services: ClipboardSyncServices, generation: UInt64
    ) async throws -> ClipboardSyncPublishedFile? {
        guard let body = descriptor.body, let size = descriptor.originalByteCount else { throw ClipboardSyncServiceError.corruptData }
        let directory = storeRoot.appendingPathComponent("SyncTransfers/Downloads/\(account.identifier)/\(control.epoch.uuidString)/\(descriptor.versionID.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var plainDigest = SHA256()
        var encryptedDigest = SHA256()
        var plainBytes: Int64 = 0
        var encryptedBytes: Int64 = 0
        for index in 0..<body.chunkCount {
            try await admitSync(generation, account: account, services: services)
            guard try syncFileIsReferenced(descriptor, account: account, epoch: control.epoch),
                  try syncFileDownloadAuthorized(descriptor, account: account, epoch: control.epoch) else { return nil }
            let url = ClipboardSyncFileTransfer.segmentURL(in: directory, index: index)
            var cached: (Data, Data)?
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let bytes = try ClipboardSyncFileTransfer.readSegment(in: directory, index: index)
                    let plaintext = try ClipboardSyncCodec.openFileSegment(bytes, descriptor: descriptor,
                        account: account, control: control, key: key, index: index)
                    cached = (bytes, plaintext)
                } catch {
                    // Only authenticated units can satisfy a durable cursor.
                    // A torn or damaged cache unit is fetched again on retry.
                    try ClipboardSyncFileTransfer.removeSegment(in: directory, index: index)
                }
            }
            let encrypted: Data
            let plaintext: Data
            if let cached {
                (encrypted, plaintext) = cached
            } else {
                encrypted = try await services.transport.downloadFileSegment(body, index: index, for: account)
                try await admitSync(generation, account: account, services: services)
                plaintext = try ClipboardSyncCodec.openFileSegment(encrypted, descriptor: descriptor,
                    account: account, control: control, key: key, index: index)
            }
            guard plaintext.count == Int(min(Int64(ClipboardSyncCodec.chunkByteCount), size - plainBytes)) else {
                throw ClipboardSyncServiceError.corruptData
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                try ClipboardSyncFileTransfer.persistSegment(encrypted, in: directory, index: index)
                try ClipboardSyncFileTransfer.syncDirectory(directory)
            }
            plainDigest.update(data: plaintext)
            encryptedDigest.update(data: encrypted)
            plainBytes += Int64(plaintext.count)
            encryptedBytes += Int64(encrypted.count)
            try await waitForWriteTurn()
            try admitSync(generation)
            try syncWrite { database in
                try database.execute(sql: """
                    INSERT INTO clipboard_sync_file_downloads(account_id, epoch, object_id, version_id, completed_chunks, completed_bytes)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, epoch, object_id, version_id) DO UPDATE SET
                        completed_chunks = excluded.completed_chunks, completed_bytes = excluded.completed_bytes, failure = NULL
                    """, arguments: [account.identifier, control.epoch.uuidString, descriptor.objectID.uuidString,
                        descriptor.versionID.uuidString, index + 1, plainBytes])
                try Self.bumpHistoryRevision(in: database)
            }
            publishMutation()
        }
        guard plainBytes == size, encryptedBytes == body.encryptedByteCount,
              Data(plainDigest.finalize()) == descriptor.contentDigest,
              Data(encryptedDigest.finalize()) == body.digest else { throw ClipboardSyncServiceError.corruptData }
        let candidate = try await ClipboardSyncFilePublication.construct(descriptor: descriptor,
            encryptedDirectory: directory, root: syncWorkingRoot, account: account, control: control, key: key)
        defer { ClipboardSyncFilePublication.discard(candidate) }
        try await admitSync(generation, account: account, services: services)
        try await waitForWriteTurn()
        try admitSync(generation)
        guard try syncFileIsReferenced(descriptor, account: account, epoch: control.epoch) else { return nil }
        return try ClipboardSyncFilePublication.publish(candidate, descriptor: descriptor, root: syncWorkingRoot,
            accountID: account.identifier, faults: faultInjector)
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
            guard let context = try syncFileContext(in: database), context.control.epoch == record.epoch,
                  context.control.keyID == record.keyID, context.control.phase == "active",
                  try Bool.fetchOne(database, SQLRequest<Bool>(literal: """
                    SELECT EXISTS(SELECT 1 FROM clipboard_sync_outbox AS outbox
                      WHERE outbox.record_id = \(record.recordID) AND outbox.account_id = \(context.account.identifier)
                        AND (\(Self.syncFileOutboxAuthority(accountID: context.account.identifier))))
                    """)) == true else { throw ClipboardSyncServiceError.accessDenied }
            try database.execute(sql: "UPDATE clipboard_sync_file_uploads SET completed_bytes = MAX(completed_bytes, ?), failure = NULL WHERE record_id = ?",
                arguments: [bytes, record.recordID])
            try Self.bumpHistoryRevision(in: database)
        }
        publishMutation()
    }
}
