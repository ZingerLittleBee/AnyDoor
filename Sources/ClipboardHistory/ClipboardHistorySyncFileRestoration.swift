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

struct ClipboardSyncFileRestorationIdentity: Hashable, Sendable {
    let sharedID: String
    let activationID: String
    let versionID: UUID
}

struct ClipboardSyncFileRestorationPreparation: Sendable {
    let identity: ClipboardSyncFileRestorationIdentity
    let upload: ClipboardSyncPendingUpload?
}

/// A display-only snapshot, never evidence for publication or body verification.
struct ClipboardSyncFileRestorationSnapshot {
    let accountID: String
    let epoch: UUID
    let rows: [Row]
    let filesByJournal: [Data: [ClipboardSyncFileRestoration]]
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
        // Start with the journal's account/epoch range, including the common
        // empty case, instead of scanning unrelated shared entries first.
        try Row.fetchAll(database, SQLRequest<Row>(literal: """
            SELECT restoration.* FROM clipboard_sync_file_rejoins AS restoration
            CROSS JOIN clipboard_sync_withdrawals AS withdrawal
            CROSS JOIN clipboard_sync_entries AS shared
            CROSS JOIN clipboard_entries AS entry
            WHERE restoration.account_id = \(accountID) AND restoration.epoch = \(epoch.uuidString)
              AND withdrawal.account_id = restoration.account_id AND withdrawal.epoch = restoration.epoch
              AND withdrawal.shared_id = restoration.shared_id
              AND shared.account_id = restoration.account_id AND shared.epoch = restoration.epoch
              AND shared.shared_id = restoration.shared_id AND entry.id = shared.local_entry_id
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

    /// Authenticate only the next body immediately before dispatch. Persisted
    /// preparation is a candidate location, never evidence that bytes are valid.
    func nextSyncFileRestoration(account: ClipboardSyncAccount, control: ClipboardSyncControl,
        key: Data, generation: UInt64, excluding: Set<ClipboardSyncFileRestorationIdentity>) async throws -> ClipboardSyncFileRestorationPreparation? {
        guard let services = syncServices else { return nil }
        let rows = try syncFileRead { try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: control.epoch, in: $0) }
        for row in rows {
            let files = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: row["journal"])
            for file in files where !file.acknowledged {
                let identity = ClipboardSyncFileRestorationIdentity(sharedID: row["shared_id"],
                    activationID: row["activation_id"], versionID: file.descriptor.versionID)
                guard !excluding.contains(identity) else { continue }
                try await admitSyncFilePublication(generation, account: account, control: control, services: services)
                guard let body = file.descriptor.body,
                      try syncFileRead({ try Self.syncFileRestorationHasMember(file.descriptor, row: row, in: $0) }) else { continue }
                var recovered = file
                recovered.directory = nil
                recovered.inline = nil
                if file.descriptor.bodyFormat != nil {
                    let uploaded = try syncFileRead { try String.fetchOne($0,
                        sql: "SELECT directory FROM clipboard_sync_file_uploads WHERE record_id = ?", arguments: [body.recordID]) }
                    let downloaded = storeRoot.appendingPathComponent("SyncTransfers/Downloads/\(account.identifier)/\(control.epoch.uuidString)/\(file.descriptor.versionID.uuidString)")
                    let candidates = [file.directory, uploaded.map { URL(fileURLWithPath: $0) }, downloaded].compactMap { $0 }
                    for directory in Set(candidates) {
                        do {
                            try await ClipboardSyncFileTransfer.verify(file.descriptor, directory: directory,
                                account: account, control: control, key: key, faults: faultInjector)
                            recovered.directory = directory
                            break
                        } catch is CancellationError { throw CancellationError() } catch { continue }
                    }
                } else {
                    let chunks = try file.inline?.chunks ?? syncFileRead { try Data.fetchAll($0,
                        sql: "SELECT ciphertext FROM clipboard_sync_chunks WHERE record_id = ? ORDER BY chunk_index", arguments: [body.recordID]) }
                    if case .fileBody(let value) = try? ClipboardSyncCodec.open(body, chunks: chunks, account: account, control: control, key: key),
                       value.objectID == file.descriptor.objectID, value.versionID == file.descriptor.versionID,
                       Int64(value.bytes.count) == file.descriptor.originalByteCount,
                       Data(SHA256.hash(data: value.bytes)) == file.descriptor.contentDigest {
                        recovered.inline = .init(record: body, chunks: chunks)
                    }
                }
                try await admitSyncFilePublication(generation, account: account, control: control, services: services)
                if recovered.directory == nil && recovered.inline == nil { recovered.completedBytes = 0 }
                let prepared = recovered
                let stored = try syncWrite { database in
                    guard let active = try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: control.epoch, in: database)
                        .first(where: { ($0["shared_id"] as String) == (row["shared_id"] as String)
                            && ($0["activation_id"] as String) == (row["activation_id"] as String) }),
                          try Self.syncFileRestorationHasMember(prepared.descriptor, row: active, in: database) else { return false }
                    var latest = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: active["journal"])
                    guard let index = latest.firstIndex(where: { $0.descriptor.versionID == prepared.descriptor.versionID }),
                          !latest[index].acknowledged else { return false }
                    latest[index] = prepared
                    try Self.saveSyncFileRestorations(latest, row: active, in: database)
                    return true
                }
                guard stored else { return .init(identity: identity, upload: nil) }
                if let directory = prepared.directory {
                    return .init(identity: identity, upload: .file(.init(record: body, directory: directory)))
                }
                if let inline = prepared.inline { return .init(identity: identity, upload: .inline(inline)) }
                try await replaceUnrecoverableSyncFile(file, row: row, account: account, control: control, key: key, generation: generation)
                return .init(identity: identity, upload: nil)
            }
        }
        return nil
    }

    /// Missing random ciphertext cannot be regenerated under its old identity.
    /// A readable current working copy can instead publish a child on its real
    /// base. The ordinary atomic version/outbox transaction makes retry safe:
    /// once stored, that child is current and this condition no longer matches.
    private func replaceUnrecoverableSyncFile(_ file: ClipboardSyncFileRestoration, row: Row,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, generation: UInt64) async throws {
        guard let services = syncServices,
              let selection = try syncFileSelection(objectID: file.descriptor.objectID),
              selection.latest.versionID == file.descriptor.versionID,
              selection.heads.map(\.versionID) == [file.descriptor.versionID],
              let source = try linkedRead({ try Self.linkedLocationSources(accountID: account.identifier,
                epoch: control.epoch, in: $0).first { $0.objectID == file.descriptor.objectID
                    && $0.baseVersionID == file.descriptor.versionID && !$0.hasPendingApplication } }) else { return }
        let inspection = Task.detached(priority: .utility) {
            try? ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: source.identity)
        }
        guard await inspection.value != nil else { return }
        try await admitSyncFilePublication(generation, account: account, control: control, services: services)
        let prepared = try await prepareFileVersion(sourceURL: source.url, objectID: source.objectID,
            versionID: UUID(), publicationID: UUID(), parents: [source.baseVersionID],
            expectedSourceIdentity: source.identity, displayName: file.descriptor.displayName,
            account: account, control: control, key: key)
        var stored = false
        defer { if !stored { try? FileManager.default.removeItem(at: prepared.uploadDirectory) } }
        let faults = faultInjector
        try await Task.detached { try faults.check(.syncFileRejoinBeforeStaging) }.value
        let saved = await Task.detached(priority: .utility) {
            try? ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: source.identity)
        }.value
        try await admitSyncFilePublication(generation, account: account, control: control, services: services)
        try await waitForWriteTurn()
        try admitSync(generation)
        stored = try syncWrite { database in
            guard try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: control.epoch, in: database)
                .contains(where: { ($0["shared_id"] as String) == (row["shared_id"] as String)
                    && ($0["activation_id"] as String) == (row["activation_id"] as String) }),
                  let current = try Self.linkedLocationSources(accountID: account.identifier,
                    epoch: control.epoch, id: source.id, in: database).first,
                  current.revision == source.revision, current.identity == source.identity,
                  current.baseVersionID == source.baseVersionID, !current.hasPendingApplication,
                  try String.fetchOne(database, sql: """
                    SELECT current_version_id FROM clipboard_sync_file_selections
                    WHERE account_id = ? AND epoch = ? AND object_id = ?
                    """, arguments: [account.identifier, control.epoch.uuidString, source.objectID.uuidString]) == file.descriptor.versionID.uuidString,
                  let digest = prepared.descriptor.contentDigest else { return false }
            let nodes = try Row.fetchAll(database, sql: """
                SELECT version_id, parents FROM clipboard_sync_file_versions
                WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [account.identifier, control.epoch.uuidString, source.objectID.uuidString]).map { row -> ClipboardSyncVersionNode in
                    guard let id = UUID(uuidString: row["version_id"]) else { throw ClipboardSyncServiceError.corruptData }
                    return .init(id: id, parents: Set(try JSONDecoder().decode([UUID].self, from: row["parents"])))
                }
            guard ClipboardSyncVersionGraph.isComplete(nodes),
                  ClipboardSyncVersionGraph.heads(nodes) == [file.descriptor.versionID] else { return false }
            try storePreparedFileVersion(prepared, account: account, control: control, in: database)
            let state: ClipboardHistoryLinkedFileLocationState = saved.map { $0.digest == digest ? .pendingUpload : .localChanges } ?? .unavailable
            try database.execute(sql: """
                UPDATE clipboard_sync_linked_locations SET base_version_id = ?, base_digest = ?, state = ?,
                    pending_version_id = ?, observed_digest = ? WHERE id = ?
                """, arguments: [prepared.descriptor.versionID.uuidString, digest, state.rawValue,
                    prepared.descriptor.versionID.uuidString, saved?.digest, source.id.uuidString])
            try Self.bumpHistoryRevision(in: database)
            try Self.bumpSearchIndexGeneration(in: database)
            return true
        }
        if stored { publishMutation() }
    }

    func syncFileRestorationIsPending(_ record: ClipboardSyncRemoteRecord, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, identity: ClipboardSyncFileRestorationIdentity? = nil, in database: Database) throws -> Bool {
        for row in try Self.activeSyncFileRejoins(accountID: account.identifier, epoch: control.epoch, in: database) {
            if let identity, (row["shared_id"] as String) != identity.sharedID
                || (row["activation_id"] as String) != identity.activationID { continue }
            if let file = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: row["journal"])
                .first(where: { $0.descriptor.body == record && !$0.acknowledged && ($0.directory != nil || $0.inline != nil) }),
               identity.map({ $0.versionID == file.descriptor.versionID }) ?? true,
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

    static func syncFileRestorationSnapshot(accountID: String, epoch: UUID, in database: Database) throws -> ClipboardSyncFileRestorationSnapshot {
        let rows = try activeSyncFileRejoins(accountID: accountID, epoch: epoch, in: database)
        var files: [Data: [ClipboardSyncFileRestoration]] = [:]
        for row in rows {
            let journal: Data = row["journal"]
            if files[journal] == nil { files[journal] = try JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: journal) }
        }
        return .init(accountID: accountID, epoch: epoch, rows: rows, filesByJournal: files)
    }

    static func pendingSyncFileRestoration(_ descriptor: ClipboardSyncFileDescriptor, accountID: String,
        epoch: UUID, in database: Database, snapshot: ClipboardSyncFileRestorationSnapshot? = nil) throws -> ClipboardSyncFileRestoration? {
        let snapshot = snapshot.flatMap { $0.accountID == accountID && $0.epoch == epoch ? $0 : nil }
        let rows = try snapshot?.rows ?? activeSyncFileRejoins(accountID: accountID, epoch: epoch, in: database)
        for row in rows {
            let journal: Data = row["journal"]
            let files = try snapshot?.filesByJournal[journal] ?? JSONDecoder().decode([ClipboardSyncFileRestoration].self, from: journal)
            if let file = files
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

}
