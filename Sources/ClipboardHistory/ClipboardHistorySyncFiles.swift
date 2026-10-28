import CryptoKit
import Foundation
import GRDB

extension ClipboardHistoryModule {
    static let automaticSyncFileDownloadBytes: Int64 = 5_000_000

    static let liveSyncFileMember = """
        EXISTS (SELECT 1 FROM clipboard_representations AS current
            WHERE current.entry_id = member.entry_id AND current.item_index = member.item_index
              AND current.representation_index = member.representation_index AND current.kind = 'fileReference')
        """

    static func syncFileSummaries(entryID: String, in database: Database) throws -> [ClipboardHistorySyncFileSummary] {
        try Row.fetchAll(database, sql: """
            SELECT member.account_id, member.epoch, version.descriptor, completed.version_id AS complete_version_id,
                   completed.transfer_state, completed.local_path, completed.local_identity
            FROM clipboard_sync_file_members AS member
            JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
            JOIN clipboard_sync_file_versions AS version ON version.account_id = member.account_id
              AND version.epoch = member.epoch AND version.object_id = member.object_id AND version.version_id = choice.current_version_id
            LEFT JOIN clipboard_sync_file_versions AS completed ON completed.account_id = member.account_id
              AND completed.epoch = member.epoch AND completed.object_id = member.object_id AND completed.version_id = choice.complete_version_id
            WHERE member.entry_id = ? AND \(liveSyncFileMember)
            ORDER BY member.item_index, member.representation_index
            """, arguments: [entryID]).map { row in
                let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"])
                let state: ClipboardHistorySyncFileState
                let completeVersion = (row["complete_version_id"] as String?).flatMap(UUID.init(uuidString:))
                let available = (row["transfer_state"] as String?) == "complete"
                    && ClipboardSyncFileIO.isAvailable(path: row["local_path"], identity: row["local_identity"])
                if available {
                    state = completeVersion == descriptor.versionID ? .complete : .updateAvailable
                } else if completeVersion != nil {
                    state = .localUnavailable
                } else {
                    state = switch descriptor.state {
                    case .available: .waitingForDownload
                    case .sourceUnavailable: .sourceUnavailable
                    case .pendingUpload: .waitingForUpload
                    case .unsupportedKind: .unsupportedKind
                    }
                }
                let transfer = try syncFileTransferSummary(descriptor, accountID: row["account_id"], epoch: row["epoch"], in: database)
                return ClipboardHistorySyncFileSummary(id: descriptor.objectID, versionID: descriptor.versionID,
                    displayName: descriptor.displayName, originalByteCount: descriptor.originalByteCount, state: state,
                    availableVersionID: available ? completeVersion : nil, transferredByteCount: transfer.bytes,
                    transferFailure: transfer.failure, downloadRequested: transfer.requested, uploadPending: transfer.uploadPending)
            }
    }

    func materializeSyncFileReferences(
        for entryID: ClipboardHistoryEntryID, in database: DatabasePool
    ) throws -> [Int: ClipboardHistoryMaterializedFileReference] {
        let rows = try database.read { database in
            try Row.fetchAll(database, sql: """
                SELECT member.item_index, version.descriptor, version.transfer_state,
                       COALESCE(location.path, version.local_path) AS local_path,
                       COALESCE(location.bookmark, version.local_bookmark) AS local_bookmark,
                       COALESCE(location.identity, version.local_identity) AS local_identity
                FROM clipboard_sync_file_members AS member
                JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                JOIN clipboard_sync_file_versions AS version ON version.account_id = member.account_id
                  AND version.epoch = member.epoch AND version.object_id = member.object_id
                  AND version.version_id = COALESCE(choice.complete_version_id, choice.current_version_id)
                LEFT JOIN clipboard_sync_linked_locations AS location ON location.id = (
                  SELECT linked.id FROM clipboard_sync_linked_locations AS linked
                  WHERE linked.account_id = member.account_id AND linked.epoch = member.epoch AND linked.object_id = member.object_id
                  ORDER BY CASE linked.kind WHEN 'original' THEN 0 WHEN 'workingCopy' THEN 1 ELSE 2 END, linked.id LIMIT 1)
                WHERE member.entry_id = ? AND (member.origin = 'remote' OR location.id IS NOT NULL) AND \(Self.liveSyncFileMember)
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
            try Row.fetchAll(database, SQLRequest<Row>(literal: """
                SELECT entry.id, representation.item_index, representation.representation_index,
                       member.display_name, member.bookmark_data, member.identity_data,
                       member.reference_provenance
                FROM clipboard_entries AS entry
                JOIN clipboard_representations AS representation ON representation.entry_id = entry.id
                JOIN clipboard_file_members AS member ON member.entry_id = entry.id
                    AND member.item_index = representation.item_index
                WHERE representation.kind = 'fileReference'
                  AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier)))
                  AND NOT EXISTS (SELECT 1 FROM clipboard_sync_file_members AS existing
                    WHERE existing.account_id = \(account.identifier) AND existing.epoch = \(control.epoch.uuidString)
                      AND existing.entry_id = entry.id AND existing.item_index = representation.item_index
                      AND existing.representation_index = representation.representation_index)
                ORDER BY entry.id, representation.item_index, representation.representation_index
                """)).map {
                    ClipboardSyncFileSource(
                        entryID: $0["id"], itemIndex: $0["item_index"],
                        representationIndex: $0["representation_index"], name: $0["display_name"],
                        bookmark: $0["bookmark_data"], identity: $0["identity_data"],
                        provenance: $0["reference_provenance"]
                    )
                }
        }
        for source in sources {
            try admitSync(generation)
            guard try syncFileRead({ try syncFileSourceIsEligible(source, account: account, in: $0) }) else { continue }
            let sampled = await Task.detached(priority: .utility) {
                ClipboardSyncFileIO.sample(source)
            }.value
            let objectID = UUID()
            let versionID = UUID()
            let frozen: ClipboardSyncFrozenFile?
            if sampled.state == .pendingUpload, let url = sampled.url,
               let bookmark = sampled.bookmark, let identity = source.identity {
                frozen = try await ClipboardSyncFileTransfer.freeze(url: url, bookmark: bookmark, identity: identity,
                    directory: storeRoot.appendingPathComponent("SyncTransfers/Uploads/\(versionID.uuidString)"),
                    account: account, control: control, key: key, objectID: objectID, versionID: versionID)
            } else { frozen = nil }
            var stored = false
            defer { if !stored, let frozen { try? FileManager.default.removeItem(at: frozen.upload.directory) } }
            try await waitForWriteTurn()
            try admitSync(generation)
            let body = try sampled.bytes.map { bytes in
                try ClipboardSyncCodec.seal(
                    .fileBody(.init(objectID: objectID, versionID: versionID, bytes: bytes)),
                    account: account, control: control, key: key, operationID: versionID
                )
            }
            let descriptor = ClipboardSyncFileDescriptor(
                objectID: objectID, versionID: versionID, displayName: source.name,
                originalByteCount: frozen?.originalByteCount ?? sampled.byteCount,
                contentDigest: frozen?.contentDigest ?? sampled.bytes.map { Data(SHA256.hash(data: $0)) },
                body: frozen?.upload.record ?? body?.record, state: frozen == nil ? sampled.state : .available,
                bodyFormat: frozen == nil ? nil : .segmentsV1
            )
            stored = try syncWrite { database in
                guard try syncFileSourceIsEligible(source, account: account, in: database) else { return false }
                if let body {
                    try storeSyncUpload(body, subjectID: objectID.uuidString, account: account, in: database)
                }
                if let frozen { try storeSyncFileUpload(frozen.upload, objectID: objectID, account: account, in: database) }
                try storeSyncFileDescriptor(descriptor, account: account, epoch: control.epoch,
                    localPath: sampled.url?.path, bookmark: sampled.bookmark, identity: source.identity,
                    transferState: body == nil && frozen == nil ? descriptor.state.rawValue : "complete", in: database)
                try database.execute(sql: """
                    INSERT INTO clipboard_sync_file_members
                        (account_id, epoch, entry_id, item_index, representation_index, object_id, version_id, origin)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'local')
                    """, arguments: [account.identifier, control.epoch.uuidString, source.entryID,
                        source.itemIndex, source.representationIndex, objectID.uuidString, versionID.uuidString])
                return true
            }
        }
    }

    private func syncFileSourceIsEligible(
        _ source: ClipboardSyncFileSource, account: ClipboardSyncAccount, in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(database, SQLRequest<Bool>(literal: """
            SELECT EXISTS (SELECT 1 FROM clipboard_entries AS entry
                WHERE entry.id = \(source.entryID)
                  AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier)))
                  AND EXISTS (SELECT 1 FROM clipboard_representations AS current
                    WHERE current.entry_id = entry.id AND current.item_index = \(source.itemIndex)
                      AND current.representation_index = \(source.representationIndex) AND current.kind = 'fileReference'))
            """)) ?? false
    }

    func syncFileDescriptor(
        entryID: String, itemIndex: Int, representationIndex: Int,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        in database: Database
    ) throws -> ClipboardSyncFileDescriptor {
        guard let data = try Data.fetchOne(database, sql: """
            SELECT version.descriptor FROM clipboard_sync_file_members AS member
            JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
            JOIN clipboard_sync_file_versions AS version ON version.account_id = member.account_id
              AND version.epoch = member.epoch AND version.object_id = member.object_id AND version.version_id = choice.current_version_id
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
            localPath: nil, bookmark: nil, identity: nil, transferState: "pending", publicationRecordID: record.recordID, in: database)
        try database.execute(sql: """
            INSERT INTO clipboard_sync_file_members
                (account_id, epoch, entry_id, item_index, representation_index, object_id, version_id, origin)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'remote')
            """, arguments: [account.identifier, record.epoch.uuidString, entryID, itemIndex,
                representationIndex, descriptor.objectID.uuidString, descriptor.versionID.uuidString])
    }

    func storeSyncFileDescriptor(
        _ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID,
        localPath: String?, bookmark: Data?, identity: Data?, transferState: String,
        parents: [UUID] = [], publicationRecordID: String? = nil, in database: Database
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
            let storedParents = try Data.fetchOne(database, sql: """
                SELECT parents FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString])
            guard let storedParents, try JSONDecoder().decode([UUID].self, from: storedParents) == parents else {
                throw ClipboardSyncServiceError.corruptData
            }
            return
        }
        try database.execute(sql: """
            INSERT INTO clipboard_sync_file_versions
                (account_id, epoch, object_id, version_id, descriptor, transfer_state,
                 local_path, local_bookmark, local_identity, parents, publication_record_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString,
                descriptor.versionID.uuidString, data, transferState, localPath, bookmark, identity, try JSONEncoder().encode(parents), publicationRecordID])
        try Self.reduceSyncFileVersions(descriptor: descriptor, accountID: account.identifier,
            epoch: epoch, complete: transferState == "complete", in: database)
    }

    func receivePendingSyncFiles(
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        services: ClipboardSyncServices, generation: UInt64
    ) async throws {
        let descriptors = try syncFileRead { database in
            try Data.fetchAll(database, sql: """
                SELECT version.descriptor FROM clipboard_sync_file_versions AS version
                JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                WHERE version.account_id = ? AND version.epoch = ? AND transfer_state != 'complete'
                  AND version.version_id = choice.current_version_id
                  AND EXISTS (SELECT 1 FROM clipboard_sync_file_members AS member
                    WHERE member.account_id = version.account_id AND member.epoch = version.epoch
                      AND member.object_id = version.object_id
                      AND \(Self.liveSyncFileMember))
                """, arguments: [account.identifier, control.epoch.uuidString]).map {
                    try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: $0)
                }
        }
        for descriptor in descriptors {
            guard descriptor.state == .available, let size = descriptor.originalByteCount,
                  try syncFileDownloadAuthorized(descriptor, account: account, epoch: control.epoch),
                  let body = descriptor.body else { continue }
            do {
            let output: ClipboardSyncPublishedFile
            if descriptor.bodyFormat == .segmentsV1 {
                guard let completed = try await receiveSegmentedSyncFile(descriptor, account: account, control: control,
                    key: key, services: services, generation: generation) else { continue }
                output = completed
            } else {
            // Bound the temporary JSON body for this small-file path. This is
            // protocol-envelope validation, not a file-size rejection policy.
            let maximumEnvelopeBytes = size * 3 + 4_096
            guard body.encryptedByteCount <= maximumEnvelopeBytes,
                  body.chunkCount <= Int(maximumEnvelopeBytes / Int64(ClipboardSyncCodec.chunkByteCount)) + 1 else {
                throw ClipboardSyncServiceError.corruptData
            }
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
            output = try ClipboardSyncFileIO.publish(
                content.bytes, descriptor: descriptor, root: syncWorkingRoot,
                accountID: account.identifier, faultInjector: faultInjector
            )
            }
            try faultInjector.check(.syncFileAfterPublication)
            try syncWrite { database in
                try database.execute(sql: """
                    UPDATE clipboard_sync_file_versions
                    SET transfer_state = 'complete', local_path = ?, local_bookmark = ?, local_identity = ?
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                    """, arguments: [output.url.path, output.bookmark, output.identity,
                        account.identifier, control.epoch.uuidString,
                        descriptor.objectID.uuidString, descriptor.versionID.uuidString])
                try Self.reduceSyncFileVersions(descriptor: descriptor, accountID: account.identifier,
                    epoch: control.epoch, complete: true, in: database)
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                try faultInjector.check(.databaseTransaction)
            }
            publishMutation()
            } catch {
                try recordSyncFileFailure(error, descriptor: descriptor, account: account, epoch: control.epoch, generation: generation)
                throw error
            }
        }
    }

    func syncFileIsReferenced(
        _ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID
    ) throws -> Bool {
        try requiredDatabase().read { database in
            try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_file_members AS member
                    JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                    WHERE member.account_id = ? AND member.epoch = ? AND member.object_id = ? AND choice.current_version_id = ?
                      AND \(Self.liveSyncFileMember))
                """, arguments: [account.identifier, epoch.uuidString,
                    descriptor.objectID.uuidString, descriptor.versionID.uuidString]) ?? false
        }
    }

    func validateSyncFileDescriptor(_ descriptor: ClipboardSyncFileDescriptor, epoch: UUID, keyID: UUID) throws {
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
            if descriptor.bodyFormat == .segmentsV1, let size = descriptor.originalByteCount {
                let unit = Int64(ClipboardSyncCodec.chunkByteCount)
                let expected = max(1, size / unit + (size % unit == 0 ? 0 : 1))
                let overhead = expected.multipliedReportingOverflow(by: 28)
                let total = size.addingReportingOverflow(overhead.partialValue)
                guard !overhead.overflow, !total.overflow, Int64(body.chunkCount) == expected,
                      body.encryptedByteCount == total.partialValue else { throw ClipboardSyncServiceError.corruptData }
            }
        } else if descriptor.body != nil || descriptor.contentDigest != nil {
            throw ClipboardSyncServiceError.corruptData
        }
    }

    /// Select the synchronous GRDB overload while preserving actor admission.
    func syncFileRead<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try requiredDatabase().read(body)
    }
}
