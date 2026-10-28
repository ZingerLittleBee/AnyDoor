import CryptoKit
import Foundation
import GRDB

struct ClipboardSyncFileRestoration: Codable, Sendable {
    let descriptor: ClipboardSyncFileDescriptor
    let parents: [UUID]
    var directory: URL?
    var inline: ClipboardSyncUpload?
    var acknowledged = false
    var completedBytes: Int64 = 0
}

extension ClipboardHistoryModule {
    static func createSyncFileRejoinSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_rejoins (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, shared_id TEXT NOT NULL,
                activation_id TEXT NOT NULL, journal BLOB NOT NULL,
                PRIMARY KEY(account_id, epoch, shared_id, activation_id)
            ) WITHOUT ROWID;
            """)
    }

    /// Snapshot retained membership once per explicit activation. A fresh peer
    /// receiving a checkpoint has no earlier local file membership to restore.
    func recordSyncFileRejoin(_ state: ClipboardSyncWithdrawal, accountID: String,
        epoch: String, in database: Database) throws {
        guard !state.withdrawn else { return }
        let files = try Row.fetchAll(database, sql: """
            SELECT DISTINCT version.descriptor, version.parents FROM clipboard_sync_entries AS shared
            JOIN clipboard_sync_file_members AS member ON member.account_id = shared.account_id
                AND member.epoch = shared.epoch AND member.entry_id = shared.local_entry_id
            JOIN clipboard_sync_file_versions AS version USING(account_id, epoch, object_id)
            WHERE shared.account_id = ? AND shared.epoch = ? AND shared.shared_id = ?
            """, arguments: [accountID, epoch, state.sharedID]).compactMap { row -> ClipboardSyncFileRestoration? in
                let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"])
                guard descriptor.body != nil else { return nil }
                return .init(descriptor: descriptor, parents: try JSONDecoder().decode([UUID].self, from: row["parents"]))
            }
        guard !files.isEmpty else { return }
        try database.execute(sql: """
            INSERT OR IGNORE INTO clipboard_sync_file_rejoins(account_id, epoch, shared_id, activation_id, journal)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [accountID, epoch, state.sharedID, state.revision.operationID, try JSONEncoder().encode(files)])
    }

    static func activeSyncFileRejoins(accountID: String, epoch: UUID, in database: Database) throws -> [Row] {
        try Row.fetchAll(database, SQLRequest<Row>(literal: """
            SELECT restoration.* FROM clipboard_sync_file_rejoins AS restoration
            JOIN clipboard_sync_withdrawals AS withdrawal USING(account_id, epoch, shared_id)
            JOIN clipboard_sync_entries AS shared USING(account_id, epoch, shared_id)
            JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            WHERE restoration.account_id = \(accountID) AND restoration.epoch = \(epoch.uuidString)
              AND withdrawal.withdrawn = 0 AND withdrawal.operation_id = restoration.activation_id
              AND (\(syncEntryPublicationAuthority(accountID: accountID)))
            """))
    }

    static func syncFileRestorationHasMember(_ descriptor: ClipboardSyncFileDescriptor, row: Row,
        in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT EXISTS(SELECT 1 FROM clipboard_sync_entries AS shared
              JOIN clipboard_sync_file_members AS member ON member.account_id = shared.account_id
                AND member.epoch = shared.epoch AND member.entry_id = shared.local_entry_id
              JOIN clipboard_representations AS representation ON representation.entry_id = member.entry_id
                AND representation.item_index = member.item_index AND representation.representation_index = member.representation_index
              WHERE shared.account_id = ? AND shared.epoch = ? AND shared.shared_id = ?
                AND member.object_id = ? AND representation.kind = 'fileReference')
            """, arguments: [row["account_id"] as String, row["epoch"] as String,
                row["shared_id"] as String, descriptor.objectID.uuidString]) ?? false
    }

    func prepareSyncFileRejoins(account: ClipboardSyncAccount, control: ClipboardSyncControl,
        key: Data, generation: UInt64) async throws {
        guard let services = syncServices else { return }
        let rows = try syncFileRead { try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: control.epoch, in: $0) }
        for row in rows {
            let files = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: row["journal"])
            for file in files where !file.acknowledged && file.directory == nil && file.inline == nil {
                try await admitSyncFilePublication(generation, account: account, control: control, services: services)
                guard let body = file.descriptor.body,
                      try syncFileRead({ try Self.syncFileRestorationHasMember(file.descriptor, row: row, in: $0) }) else { continue }
                var recovered = file
                if file.descriptor.bodyFormat == .segmentsV1 {
                    let uploaded = try syncFileRead { try String.fetchOne($0,
                        sql: "SELECT directory FROM clipboard_sync_file_uploads WHERE record_id = ?", arguments: [body.recordID]) }
                    let downloaded = storeRoot.appendingPathComponent("SyncTransfers/Downloads/\(account.identifier)/\(control.epoch.uuidString)/\(file.descriptor.versionID.uuidString)")
                    for directory in uploaded.map({ [URL(fileURLWithPath: $0), downloaded] }) ?? [downloaded] {
                        do {
                            try await Self.verifySyncFileRestoration(file.descriptor, directory: directory,
                                account: account, control: control, key: key)
                            recovered.directory = directory
                            break
                        } catch is CancellationError { throw CancellationError() } catch { continue }
                    }
                } else {
                    let chunks = try syncFileRead { try Data.fetchAll($0,
                        sql: "SELECT ciphertext FROM clipboard_sync_chunks WHERE record_id = ? ORDER BY chunk_index", arguments: [body.recordID]) }
                    if case .fileBody(let value) = try? ClipboardSyncCodec.open(body, chunks: chunks, account: account, control: control, key: key),
                       value.objectID == file.descriptor.objectID, value.versionID == file.descriptor.versionID,
                       Int64(value.bytes.count) == file.descriptor.originalByteCount,
                       Data(SHA256.hash(data: value.bytes)) == file.descriptor.contentDigest {
                        recovered.inline = .init(record: body, chunks: chunks)
                    }
                }
                try await admitSyncFilePublication(generation, account: account, control: control, services: services)
                guard recovered.directory != nil || recovered.inline != nil else { continue }
                let prepared = recovered
                try syncWrite { database in
                    guard let active = try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: control.epoch, in: database)
                        .first(where: { ($0["shared_id"] as String) == (row["shared_id"] as String)
                            && ($0["activation_id"] as String) == (row["activation_id"] as String) }),
                          try Self.syncFileRestorationHasMember(prepared.descriptor, row: active, in: database) else { return }
                    var latest = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: active["journal"])
                    guard let index = latest.firstIndex(where: { $0.descriptor.versionID == prepared.descriptor.versionID }),
                          !latest[index].acknowledged else { return }
                    latest[index] = prepared
                    try Self.saveSyncFileRestorations(latest, row: active, in: database)
                }
            }
        }
    }

    func nextSyncFileRestoration(account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncPendingUpload? {
        try syncFileRead { database in
            for row in try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: control.epoch, in: database) {
                for file in try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: row["journal"]) where !file.acknowledged {
                    guard let body = file.descriptor.body, try Self.syncFileRestorationHasMember(file.descriptor, row: row, in: database) else { continue }
                    if let directory = file.directory { return .file(.init(record: body, directory: directory)) }
                    if let inline = file.inline { return .inline(inline) }
                }
            }
            return nil
        }
    }

    func syncFileRestorationIsPending(_ record: ClipboardSyncRemoteRecord, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, in database: Database) throws -> Bool {
        for row in try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: control.epoch, in: database) {
            if let file = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: row["journal"])
                .first(where: { $0.descriptor.body == record && !$0.acknowledged && ($0.directory != nil || $0.inline != nil) }),
               try Self.syncFileRestorationHasMember(file.descriptor, row: row, in: database) { return true }
        }
        return false
    }

    func recordSyncFileRestorationAcknowledged(_ record: ClipboardSyncRemoteRecord, account: ClipboardSyncAccount,
        in database: Database) throws {
        for row in try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: record.epoch, in: database) {
            var files = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: row["journal"])
            guard let index = files.firstIndex(where: { $0.descriptor.body == record }),
                  try Self.syncFileRestorationHasMember(files[index].descriptor, row: row, in: database) else { continue }
            files[index].acknowledged = true
            files[index].completedBytes = record.encryptedByteCount
            try Self.saveSyncFileRestorations(files, row: row, in: database)
            try Self.rememberSyncFileRecord(record, objectID: files[index].descriptor.objectID.uuidString,
                sharedID: row["shared_id"], accountID: account.identifier, in: database)
        }
    }

    func recordSyncFileRestorationProgress(_ bytes: Int64, record: ClipboardSyncRemoteRecord,
        account: ClipboardSyncAccount, generation: UInt64) async throws {
        try await waitForWriteTurn()
        try admitSync(generation)
        try syncWrite { database in
            guard let context = try syncFileContext(in: database), context.account == account,
                  context.control.epoch == record.epoch, context.control.keyID == record.keyID,
                  try syncFileRestorationIsPending(record, account: account, control: context.control, in: database) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            for row in try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: record.epoch, in: database) {
                var files = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: row["journal"])
                guard let index = files.firstIndex(where: { $0.descriptor.body == record && !$0.acknowledged }) else { continue }
                files[index].completedBytes = max(files[index].completedBytes, bytes)
                try Self.saveSyncFileRestorations(files, row: row, in: database)
            }
            try Self.bumpHistoryRevision(in: database)
        }
        publishMutation()
    }

    static func pendingSyncFileRestoration(_ descriptor: ClipboardSyncFileDescriptor, accountID: String,
        epoch: UUID, in database: Database) throws -> ClipboardSyncFileRestoration? {
        for row in try activeSyncFileRejoins(accountID: accountID, epoch: epoch, in: database) {
            if let file = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: row["journal"])
                .first(where: { $0.descriptor == descriptor && !$0.acknowledged }),
               try syncFileRestorationHasMember(descriptor, row: row, in: database) { return file }
        }
        return nil
    }

    static func saveSyncFileRestorations(_ files: [ClipboardSyncFileRestoration], row: Row, in database: Database) throws {
        try database.execute(sql: """
            UPDATE clipboard_sync_file_rejoins SET journal = ? WHERE account_id = ? AND epoch = ? AND shared_id = ? AND activation_id = ?
            """, arguments: [try JSONEncoder().encode(files), row["account_id"] as String, row["epoch"] as String,
                row["shared_id"] as String, row["activation_id"] as String])
    }

    @concurrent
    static func verifySyncFileRestoration(_ descriptor: ClipboardSyncFileDescriptor, directory: URL,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data) async throws {
        guard let body = descriptor.body else { throw ClipboardSyncServiceError.corruptData }
        var plain = SHA256(), encrypted = SHA256()
        var count: Int64 = 0, cipherCount: Int64 = 0
        for index in 0..<body.chunkCount {
            try Task.checkCancellation()
            let bytes = try ClipboardSyncFileTransfer.readSegment(in: directory, index: index)
            let data = try ClipboardSyncCodec.openFileSegment(bytes, descriptor: descriptor,
                account: account, control: control, key: key, index: index)
            plain.update(data: data); encrypted.update(data: bytes)
            count += Int64(data.count); cipherCount += Int64(bytes.count)
        }
        guard count == descriptor.originalByteCount, Data(plain.finalize()) == descriptor.contentDigest,
              cipherCount == body.encryptedByteCount, Data(encrypted.finalize()) == body.digest else { throw ClipboardSyncServiceError.corruptData }
    }
}
