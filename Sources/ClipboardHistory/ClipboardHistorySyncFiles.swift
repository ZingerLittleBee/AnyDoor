import CryptoKit
import Foundation
import GRDB

extension ClipboardHistoryModule {
    static let automaticSyncFileDownloadBytes: Int64 = 5_000_000

    static func syncFileSummaries(entryID: String, in database: Database) throws -> [ClipboardHistorySyncFileSummary] {
        try Row.fetchAll(database, sql: """
            SELECT version.descriptor, version.transfer_state, version.local_path, version.local_identity
            FROM clipboard_sync_file_members AS member
            JOIN clipboard_sync_file_versions AS version USING(account_id, epoch, object_id, version_id)
            WHERE member.entry_id = ? ORDER BY member.item_index, member.representation_index
            """, arguments: [entryID]).map { row in
                let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"])
                let state: ClipboardHistorySyncFileState
                if (row["transfer_state"] as String) == "complete" {
                    state = ClipboardSyncFileIO.isAvailable(path: row["local_path"], identity: row["local_identity"])
                        ? .complete : .localUnavailable
                } else {
                    state = switch descriptor.state {
                    case .available: .waitingForDownload
                    case .sourceUnavailable: .sourceUnavailable
                    case .pendingUpload: .waitingForUpload
                    case .unsupportedKind: .unsupportedKind
                    }
                }
                return ClipboardHistorySyncFileSummary(id: descriptor.objectID, versionID: descriptor.versionID,
                    displayName: descriptor.displayName, originalByteCount: descriptor.originalByteCount, state: state)
            }
    }

    func materializeSyncFileReferences(
        for entryID: ClipboardHistoryEntryID, in database: DatabasePool
    ) throws -> [Int: ClipboardHistoryMaterializedFileReference] {
        let rows = try database.read { database in
            try Row.fetchAll(database, sql: """
                SELECT member.item_index, version.descriptor, version.transfer_state,
                       version.local_path, version.local_bookmark, version.local_identity
                FROM clipboard_sync_file_members AS member
                JOIN clipboard_sync_file_versions AS version USING(account_id, epoch, object_id, version_id)
                WHERE member.entry_id = ? AND member.origin = 'remote'
                ORDER BY member.item_index, member.representation_index
                """, arguments: [entryID.value.uuidString.lowercased()])
        }
        let pendingCount = rows.count { ($0["transfer_state"] as String) != "complete" }
        guard pendingCount == 0 else { throw ClipboardHistoryModuleError.syncFilesPending(entryID, count: pendingCount) }
        var references: [Int: ClipboardHistoryMaterializedFileReference] = [:]
        var missingCount = 0
        for row in rows {
            let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"])
            guard let bookmark: Data = row["local_bookmark"], let identity: Data = row["local_identity"],
                  let url = try? ClipboardSyncFileIO.resolve(bookmark: bookmark, identity: identity) else {
                missingCount += 1
                continue
            }
            references[row["item_index"]] = ClipboardHistoryMaterializedFileReference(
                capturedPath: row["local_path"], displayName: descriptor.displayName, currentURL: url
            )
        }
        guard missingCount == 0 else { throw ClipboardHistoryModuleError.fileReferencesUnavailable(entryID, count: missingCount) }
        return references
    }

    static func createSyncFileSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_versions (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL,
                object_id TEXT NOT NULL, version_id TEXT NOT NULL,
                descriptor BLOB NOT NULL, transfer_state TEXT NOT NULL,
                local_path TEXT, local_bookmark BLOB, local_identity BLOB,
                PRIMARY KEY(account_id, epoch, object_id, version_id)
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_file_members (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL,
                entry_id TEXT NOT NULL REFERENCES clipboard_entries(id) ON DELETE CASCADE,
                item_index INTEGER NOT NULL, representation_index INTEGER NOT NULL,
                object_id TEXT NOT NULL, version_id TEXT NOT NULL, origin TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, entry_id, item_index, representation_index),
                FOREIGN KEY(account_id, epoch, object_id, version_id)
                    REFERENCES clipboard_sync_file_versions(account_id, epoch, object_id, version_id)
            ) WITHOUT ROWID;
            """)
    }

    /// Sampling happens before the entry-envelope transaction, outside the actor.
    /// Only the frozen encrypted body and its descriptor enter that transaction.
    func prepareSyncFiles(
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        generation: UInt64
    ) async throws {
        let sources = try syncFileRead { database in
            try Row.fetchAll(database, sql: """
                SELECT entry.id, representation.item_index, representation.representation_index,
                       member.display_name, member.bookmark_data, member.identity_data,
                       member.reference_provenance
                FROM clipboard_entries AS entry
                JOIN clipboard_representations AS representation ON representation.entry_id = entry.id
                JOIN clipboard_file_members AS member ON member.entry_id = entry.id
                    AND member.item_index = representation.item_index
                WHERE representation.kind = 'fileReference'
                  AND EXISTS (SELECT 1 FROM clipboard_entry_tags AS membership
                    JOIN clipboard_sync_tags AS selected ON selected.tag_id = membership.tag_id
                    WHERE membership.entry_id = entry.id AND selected.account_id = ? AND selected.selected = 1
                      AND (selected.locally_authorized = 1 OR NOT EXISTS (
                        SELECT 1 FROM clipboard_sync_entries AS former
                        WHERE former.local_entry_id = entry.id AND former.account_id != selected.account_id)))
                  AND NOT EXISTS (SELECT 1 FROM clipboard_sync_file_members AS existing
                    WHERE existing.account_id = ? AND existing.epoch = ? AND existing.entry_id = entry.id
                      AND existing.item_index = representation.item_index
                      AND existing.representation_index = representation.representation_index)
                ORDER BY entry.id, representation.item_index, representation.representation_index
                """, arguments: [account.identifier, account.identifier, control.epoch.uuidString]).map {
                    ClipboardSyncFileSource(
                        entryID: $0["id"], itemIndex: $0["item_index"],
                        representationIndex: $0["representation_index"], name: $0["display_name"],
                        bookmark: $0["bookmark_data"], identity: $0["identity_data"],
                        provenance: $0["reference_provenance"]
                    )
                }
        }
        for source in sources {
            let sampled = await Task.detached(priority: .utility) {
                ClipboardSyncFileIO.sample(source)
            }.value
            try await waitForWriteTurn()
            try admitSync(generation)
            let objectID = UUID()
            let versionID = UUID()
            let body = try sampled.bytes.map { bytes in
                try ClipboardSyncCodec.seal(
                    .fileBody(.init(objectID: objectID, versionID: versionID, bytes: bytes)),
                    account: account, control: control, key: key, operationID: versionID
                )
            }
            let descriptor = ClipboardSyncFileDescriptor(
                objectID: objectID, versionID: versionID, displayName: source.name,
                originalByteCount: sampled.byteCount,
                contentDigest: sampled.bytes.map { Data(SHA256.hash(data: $0)) },
                body: body?.record, state: sampled.state
            )
            try syncWrite { database in
                guard try syncFileSourceIsEligible(source, account: account, in: database) else { return }
                if let body {
                    try storeSyncUpload(body, subjectID: objectID.uuidString, account: account, in: database)
                }
                try storeSyncFileDescriptor(descriptor, account: account, epoch: control.epoch,
                    localPath: sampled.url?.path, bookmark: sampled.bookmark, identity: source.identity,
                    transferState: body == nil ? descriptor.state.rawValue : "complete", in: database)
                try database.execute(sql: """
                    INSERT INTO clipboard_sync_file_members
                        (account_id, epoch, entry_id, item_index, representation_index, object_id, version_id, origin)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'local')
                    """, arguments: [account.identifier, control.epoch.uuidString, source.entryID,
                        source.itemIndex, source.representationIndex, objectID.uuidString, versionID.uuidString])
            }
        }
    }

    private func syncFileSourceIsEligible(
        _ source: ClipboardSyncFileSource, account: ClipboardSyncAccount, in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT EXISTS (SELECT 1 FROM clipboard_entry_tags AS membership
                JOIN clipboard_sync_tags AS selected ON selected.tag_id = membership.tag_id
                WHERE membership.entry_id = ? AND selected.account_id = ? AND selected.selected = 1
                  AND (selected.locally_authorized = 1 OR NOT EXISTS (
                    SELECT 1 FROM clipboard_sync_entries AS former
                    WHERE former.local_entry_id = membership.entry_id AND former.account_id != selected.account_id)))
            """, arguments: [source.entryID, account.identifier]) ?? false
    }

    func syncFileDescriptor(
        entryID: String, itemIndex: Int, representationIndex: Int,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        in database: Database
    ) throws -> ClipboardSyncFileDescriptor {
        guard let data = try Data.fetchOne(database, sql: """
            SELECT version.descriptor FROM clipboard_sync_file_members AS member
            JOIN clipboard_sync_file_versions AS version USING(account_id, epoch, object_id, version_id)
            WHERE member.account_id = ? AND member.epoch = ? AND member.entry_id = ?
                AND member.item_index = ? AND member.representation_index = ?
            """, arguments: [account.identifier, control.epoch.uuidString, entryID, itemIndex, representationIndex]) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: data)
    }

    func importSyncFileDescriptor(
        _ descriptor: ClipboardSyncFileDescriptor, entryID: String, itemIndex: Int,
        representationIndex: Int, account: ClipboardSyncAccount,
        record: ClipboardSyncRemoteRecord, in database: Database
    ) throws {
        try validateSyncFileDescriptor(descriptor, epoch: record.epoch, keyID: record.keyID)
        try storeSyncFileDescriptor(descriptor, account: account, epoch: record.epoch,
            localPath: nil, bookmark: nil, identity: nil, transferState: "pending", in: database)
        try database.execute(sql: """
            INSERT INTO clipboard_sync_file_members
                (account_id, epoch, entry_id, item_index, representation_index, object_id, version_id, origin)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'remote')
            """, arguments: [account.identifier, record.epoch.uuidString, entryID, itemIndex,
                representationIndex, descriptor.objectID.uuidString, descriptor.versionID.uuidString])
    }

    private func storeSyncFileDescriptor(
        _ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID,
        localPath: String?, bookmark: Data?, identity: Data?, transferState: String, in database: Database
    ) throws {
        let data = try JSONEncoder().encode(descriptor)
        if let existing = try Data.fetchOne(database, sql: """
            SELECT descriptor FROM clipboard_sync_file_versions
            WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
            """, arguments: [account.identifier, epoch.uuidString,
                descriptor.objectID.uuidString, descriptor.versionID.uuidString]) {
            guard try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: existing) == descriptor else {
                throw ClipboardSyncServiceError.corruptData
            }
            return
        }
        try database.execute(sql: """
            INSERT INTO clipboard_sync_file_versions
                (account_id, epoch, object_id, version_id, descriptor, transfer_state,
                 local_path, local_bookmark, local_identity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString,
                descriptor.versionID.uuidString, data, transferState, localPath, bookmark, identity])
    }

    func receivePendingSyncFiles(
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        services: ClipboardSyncServices, generation: UInt64
    ) async throws {
        let descriptors = try syncFileRead { database in
            try Data.fetchAll(database, sql: """
                SELECT version.descriptor FROM clipboard_sync_file_versions AS version
                WHERE account_id = ? AND epoch = ? AND transfer_state != 'complete'
                  AND EXISTS (SELECT 1 FROM clipboard_sync_file_members AS member
                    WHERE member.account_id = version.account_id AND member.epoch = version.epoch
                      AND member.object_id = version.object_id AND member.version_id = version.version_id
                      AND member.origin = 'remote')
                """, arguments: [account.identifier, control.epoch.uuidString]).map {
                    try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: $0)
                }
        }
        for descriptor in descriptors {
            guard descriptor.state == .available, let size = descriptor.originalByteCount,
                  size <= Self.automaticSyncFileDownloadBytes, let body = descriptor.body else { continue }
            try await admitSync(generation, account: account, services: services)
            let chunks = try await services.transport.download(body, for: account)
            try await admitSync(generation, account: account, services: services)
            guard case .fileBody(let content) = try ClipboardSyncCodec.open(
                body, chunks: chunks, account: account, control: control, key: key
            ), content.objectID == descriptor.objectID, content.versionID == descriptor.versionID,
               Int64(content.bytes.count) == size, Data(SHA256.hash(data: content.bytes)) == descriptor.contentDigest else {
                throw ClipboardSyncServiceError.corruptData
            }
            // Authentication is complete before any ordinary file is created.
            // Publication stays synchronous with final admission and DB commit.
            try await waitForWriteTurn()
            try admitSync(generation)
            guard try syncFileIsReferenced(descriptor, account: account, epoch: control.epoch) else { continue }
            let output = try ClipboardSyncFileIO.publish(
                content.bytes, descriptor: descriptor, root: syncWorkingRoot,
                accountID: account.identifier, faultInjector: faultInjector
            )
            try faultInjector.check(.syncFileAfterPublication)
            try syncWrite { database in
                try database.execute(sql: """
                    UPDATE clipboard_sync_file_versions
                    SET transfer_state = 'complete', local_path = ?, local_bookmark = ?, local_identity = ?
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                    """, arguments: [output.url.path, output.bookmark, output.identity,
                        account.identifier, control.epoch.uuidString,
                        descriptor.objectID.uuidString, descriptor.versionID.uuidString])
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                try faultInjector.check(.databaseTransaction)
            }
            publishMutation()
        }
    }

    private func syncFileIsReferenced(
        _ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID
    ) throws -> Bool {
        try requiredDatabase().read { database in
            try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_file_members
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?)
                """, arguments: [account.identifier, epoch.uuidString,
                    descriptor.objectID.uuidString, descriptor.versionID.uuidString]) ?? false
        }
    }

    private func validateSyncFileDescriptor(_ descriptor: ClipboardSyncFileDescriptor, epoch: UUID, keyID: UUID) throws {
        guard ClipboardSyncFileIO.validFilename(descriptor.displayName),
              descriptor.originalByteCount.map({ $0 >= 0 }) ?? true else {
            throw ClipboardSyncServiceError.corruptData
        }
        if descriptor.state == .available {
            guard descriptor.originalByteCount != nil, descriptor.contentDigest?.count == 32,
                  let body = descriptor.body, body.epoch == epoch, body.keyID == keyID,
                  body.kind == .fileBody, body.operationID == descriptor.versionID,
                  body.chunkCount > 0, body.encryptedByteCount > 0, body.digest.count == 32 else {
                throw ClipboardSyncServiceError.corruptData
            }
        } else if descriptor.body != nil || descriptor.contentDigest != nil {
            throw ClipboardSyncServiceError.corruptData
        }
    }

    /// Select the synchronous GRDB overload while preserving actor admission.
    private func syncFileRead<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try requiredDatabase().read(body)
    }
}
