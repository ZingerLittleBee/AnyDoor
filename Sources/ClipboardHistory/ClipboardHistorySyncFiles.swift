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
                   completed.transfer_state, completed.local_path, completed.local_identity,
                   (member.origin = 'local' AND COALESCE(source.reference_provenance, '') IN ('ordinary', 'legacyUnverified')
                     AND COALESCE(version.local_bookmark, source.bookmark_data) IS NOT NULL
                     AND COALESCE(version.local_identity, source.identity_data) IS NOT NULL) AS has_retry_source
            FROM clipboard_sync_file_members AS member
            LEFT JOIN clipboard_file_members AS source ON source.entry_id = member.entry_id AND source.item_index = member.item_index
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
                let linked = try usableLinkedFileReference(objectID: descriptor.objectID,
                    accountID: row["account_id"], epoch: row["epoch"], in: database)
                let available = (row["transfer_state"] as String?) == "complete"
                    && (linked.exists ? linked.reference != nil
                        : ClipboardSyncFileIO.isAvailable(path: row["local_path"], identity: row["local_identity"]))
                let availableVersion = linked.reference?.versionID ?? completeVersion
                if available {
                    state = availableVersion == descriptor.versionID ? .complete : .updateAvailable
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
                let conflict = try syncFileHasConflict(objectID: descriptor.objectID, accountID: row["account_id"], epoch: row["epoch"], in: database)
                let sourcePending = descriptor.state == .sourceUnavailable && (row["has_retry_source"] as Bool)
                return ClipboardHistorySyncFileSummary(id: descriptor.objectID, versionID: descriptor.versionID,
                    displayName: descriptor.displayName, originalByteCount: descriptor.originalByteCount, state: state,
                    availableVersionID: available ? availableVersion : nil, transferredByteCount: transfer.bytes,
                    transferFailure: transfer.failure, downloadRequested: transfer.requested, uploadPending: transfer.uploadPending || sourcePending,
                    hasConflict: conflict, transferTotalByteCount: descriptor.streamByteCount)
            }
    }

    func materializeSyncFileReferences(
        for entryID: ClipboardHistoryEntryID, in database: DatabasePool
    ) throws -> [Int: ClipboardHistoryMaterializedFileReference] {
        let rows = try database.read { database in
            try Row.fetchAll(database, sql: """
                SELECT member.item_index, member.account_id, member.epoch, version.descriptor, version.transfer_state,
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
            let linked = try database.read { try Self.usableLinkedFileReference(objectID: descriptor.objectID,
                accountID: row["account_id"], epoch: row["epoch"], in: $0) }
            let bookmark: Data? = linked.exists ? linked.reference?.bookmark : row["local_bookmark"]
            let identity: Data? = linked.exists ? linked.reference?.identity : row["local_identity"]
            guard let bookmark, let identity,
                  let url = try? ClipboardSyncFileIO.resolve(bookmark: bookmark, identity: identity) else {
                missingCount += 1
                continue
            }
            references[row["item_index"]] = ClipboardHistoryMaterializedFileReference(
                capturedPath: linked.reference?.path ?? row["local_path"], displayName: descriptor.displayName, currentURL: url
            )
        }
        guard missingCount == 0 else { throw ClipboardHistoryModuleError.fileReferencesUnavailable(entryID, count: missingCount) }
        return references
    }

    private static func usableLinkedFileReference(objectID: UUID, accountID: String, epoch: String,
        in database: Database) throws -> (exists: Bool, reference: (path: String, bookmark: Data, identity: Data, versionID: UUID)?) {
        let rows = try Row.fetchAll(database, sql: """
            SELECT path, bookmark, identity, native_identity, state, base_version_id FROM clipboard_sync_linked_locations
            WHERE account_id = ? AND epoch = ? AND object_id = ?
            ORDER BY CASE kind WHEN 'original' THEN 0 WHEN 'workingCopy' THEN 1 ELSE 2 END, id
            """, arguments: [accountID, epoch, objectID.uuidString])
        for row in rows where !["unavailable", "detached", "identityUncertain"].contains(row["state"] as String) {
            let path: String = row["path"]
            let identity: Data = row["identity"]
            if ClipboardLinkedIdentityResolution.isAvailable(path: path, identity: identity, nativeIdentity: row["native_identity"]),
               let versionID = UUID(uuidString: row["base_version_id"]) {
                return (true, (path, row["bookmark"], identity, versionID))
            }
        }
        return (!rows.isEmpty, nil)
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
        guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
        for source in sources {
            try await admitSyncFilePublication(generation, account: account, control: control, services: services)
            guard try syncFileRead({ try syncFileSourceIsEligible(source, account: account, in: $0) }) else { continue }
            let sampled = await Task.detached(priority: .utility) {
                ClipboardSyncFileIO.sample(source)
            }.value
            try admitSync(generation)
            guard try syncFileRead({ try syncFileSourceIsEligible(source, account: account, in: $0) }) else { continue }
            let objectID = UUID()
            let versionID = UUID()
            var frozen: ClipboardSyncFrozenFile?
            var sourceFailure: Error?
            if sampled.state == .pendingUpload, let url = sampled.url,
               let bookmark = sampled.bookmark, let identity = source.identity {
                do {
                    frozen = try await ClipboardSyncFileTransfer.freeze(url: url, bookmark: bookmark, identity: identity,
                        directory: storeRoot.appendingPathComponent("SyncTransfers/Uploads/\(versionID.uuidString)"),
                        account: account, control: control, key: key, objectID: objectID, versionID: versionID, faults: faultInjector)
                } catch {
                    guard Self.isIsolatedSyncSourceFailure(error) else { throw error }
                    sourceFailure = error
                }
            }
            var stored = false
            defer { if !stored, let frozen { try? FileManager.default.removeItem(at: frozen.upload.directory) } }
            try await admitSyncFilePublication(generation, account: account, control: control, services: services)
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
                body: frozen?.upload.record ?? body?.record,
                state: sourceFailure != nil ? .sourceUnavailable : (frozen == nil ? sampled.state : .available),
                bodyFormat: frozen?.bodyFormat, kind: frozen?.kind, encodedByteCount: frozen?.encodedByteCount
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
            if stored, let sourceFailure {
                try recordSyncFileFailure(sourceFailure, descriptor: descriptor, account: account, epoch: control.epoch, generation: generation)
                try deferSyncFileWork(.source(objectID), error: sourceFailure, account: account, control: control, generation: generation)
            }
        }
        // Retry the captured identity once its initial descriptor is staged.
        // Recovered sources and legacy large files become immutable children.
        let retryable = try syncFileRead { database in
            try Row.fetchAll(database, SQLRequest<Row>(literal: """
                SELECT DISTINCT version.object_id, version.version_id,
                    member.entry_id, member.item_index, member.representation_index,
                    source.display_name, source.reference_provenance,
                    COALESCE(version.local_bookmark, source.bookmark_data) AS bookmark,
                    COALESCE(version.local_identity, source.identity_data) AS identity
                FROM clipboard_sync_file_versions AS version
                JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                JOIN clipboard_sync_file_members AS member USING(account_id, epoch, object_id)
                JOIN clipboard_entries AS entry ON entry.id = member.entry_id
                JOIN clipboard_file_members AS source ON source.entry_id = member.entry_id AND source.item_index = member.item_index
                JOIN clipboard_sync_entries AS shared ON shared.account_id = member.account_id
                    AND shared.epoch = member.epoch AND shared.local_entry_id = member.entry_id
                WHERE version.account_id = \(account.identifier) AND version.epoch = \(control.epoch.uuidString)
                  AND choice.current_version_id = version.version_id AND member.origin = 'local'
                  AND version.transfer_state IN ('pendingUpload', 'sourceUnavailable')
                  AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier)))
                """)).compactMap { row -> (UUID, UUID, ClipboardSyncFileSource)? in
                guard let objectID = UUID(uuidString: row["object_id"]), let versionID = UUID(uuidString: row["version_id"]),
                      let bookmark: Data = row["bookmark"], let identity: Data = row["identity"] else { return nil }
                return (objectID, versionID, ClipboardSyncFileSource(entryID: row["entry_id"], itemIndex: row["item_index"],
                    representationIndex: row["representation_index"], name: row["display_name"],
                    bookmark: bookmark, identity: identity, provenance: row["reference_provenance"]))
            }
        }
        for (objectID, parent, source) in retryable {
            try await admitSyncFilePublication(generation, account: account, control: control, services: services)
            let work = ClipboardSyncFileWork.source(objectID)
            guard try !shouldDeferSyncFileWork(work, account: account, control: control) else { continue }
            guard try syncFileRead({ try syncFileSourceIsEligible(source, account: account, in: $0) }) else { continue }
            let sampled = await Task.detached(priority: .utility) { ClipboardSyncFileIO.sample(source) }.value
            try admitSync(generation)
            guard sampled.state == .available || sampled.state == .pendingUpload,
                  let url = sampled.url, let identity = source.identity else { continue }
            do {
                _ = try await publishFileVersion(sourceURL: url, objectID: objectID, parents: [parent], expectedSourceIdentity: identity)
                try syncWrite { try completeSyncFileWork(work, account: account, control: control, in: $0) }
            } catch {
                guard Self.isIsolatedSyncSourceFailure(error) else { throw error }
                try deferSyncFileWork(work, error: error, account: account, control: control, generation: generation)
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
        record: ClipboardSyncRemoteRecord, parents: [UUID] = [], in database: Database
    ) throws {
        try validateSyncFileDescriptor(descriptor, epoch: record.epoch, keyID: record.keyID)
        try storeSyncFileDescriptor(descriptor, account: account, epoch: record.epoch,
            localPath: nil, bookmark: nil, identity: nil, transferState: "pending", parents: parents, publicationRecordID: record.recordID, in: database)
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
        try Self.validateSyncFileAncestry(accountID: account.identifier, epoch: epoch, objectID: descriptor.objectID, in: database)
        try Self.reduceSyncFileVersions(descriptor: descriptor, accountID: account.identifier,
            epoch: epoch, complete: transferState == "complete", in: database)
    }

    func receivePendingSyncFiles(
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        services: ClipboardSyncServices, generation: UInt64
    ) async throws {
        try stageAutomaticFileConflictDownloads(account: account, control: control)
        let descriptors = try syncFileRead { database in
            try Data.fetchAll(database, sql: """
                SELECT version.descriptor FROM clipboard_sync_file_versions AS version
                JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                WHERE version.account_id = ? AND version.epoch = ?
                  AND ((transfer_state != 'complete' AND version.version_id = choice.current_version_id)
                    OR \(Self.pinnedFileConflictDownload) OR \(Self.automaticFileConflictDownload))
                  AND EXISTS (SELECT 1 FROM clipboard_sync_file_members AS member
                    WHERE member.account_id = version.account_id AND member.epoch = version.epoch
                      AND member.object_id = version.object_id
                      AND \(Self.liveSyncFileMember))
                """, arguments: [account.identifier, control.epoch.uuidString]).map {
                    try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: $0)
                }
        }
        for descriptor in descriptors {
            try validateSyncFileDescriptor(descriptor, epoch: control.epoch, keyID: control.keyID)
            let requirement = try syncFileDownloadRequirement(descriptor, account: account, epoch: control.epoch)
            guard requirement.ancestryComplete else { continue }
            guard descriptor.state == .available, let size = descriptor.originalByteCount,
                  try syncFileDownloadAuthorized(descriptor, account: account, epoch: control.epoch),
                  let body = descriptor.body else { continue }
            guard try syncFileIsReferenced(descriptor, account: account, epoch: control.epoch),
                  try !shouldDeferSyncFileWork(.download(descriptor.versionID), account: account, control: control,
                    reportMissingRecord: requirement.reportMissingRecord) else { continue }
            do {
            let output: ClipboardSyncPublishedFile
            if descriptor.bodyFormat != nil {
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
            try await admitSyncFilePublication(generation, account: account, control: control, services: services)
            try await waitForWriteTurn()
            try admitSync(generation)
            guard try syncFileIsReferenced(descriptor, account: account, epoch: control.epoch) else { continue }
            output = try ClipboardSyncFileIO.publish(
                content.bytes, descriptor: descriptor, root: try syncFilePublicationRoot(descriptor, account: account, epoch: control.epoch),
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
                let pinned = try Bool.fetchOne(database, sql: """
                    SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins WHERE account_id = ? AND epoch = ?
                      AND object_id = ? AND version_id = ? AND download_requested = 1)
                      OR EXISTS(SELECT 1 FROM clipboard_sync_file_auto_candidates WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?)
                    """, arguments: [account.identifier, control.epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString,
                        account.identifier, control.epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString]) ?? false
                if !pinned {
                    try Self.reduceSyncFileVersions(descriptor: descriptor, accountID: account.identifier,
                        epoch: control.epoch, complete: true, in: database)
                }
                try database.execute(sql: """
                    UPDATE clipboard_sync_file_conflict_pins SET download_completed = 1
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ? AND download_requested = 1
                    """, arguments: [account.identifier, control.epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString])
                try database.execute(sql: """
                    UPDATE clipboard_sync_file_auto_candidates SET completed = 1
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                    """, arguments: [account.identifier, control.epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString])
                try database.execute(sql: """
                    UPDATE clipboard_sync_file_downloads SET failure = NULL
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                    """, arguments: [account.identifier, control.epoch.uuidString,
                        descriptor.objectID.uuidString, descriptor.versionID.uuidString])
                try completeSyncFileWork(.download(descriptor.versionID), account: account, control: control, in: database)
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                try faultInjector.check(.databaseTransaction)
            }
            publishMutation()
            } catch {
                try recordSyncFileFailure(error, descriptor: descriptor, account: account, epoch: control.epoch, generation: generation)
                if Self.isIsolatedSyncFileFailure(error) {
                    try deferSyncFileWork(.download(descriptor.versionID), error: error,
                        account: account, control: control, generation: generation,
                        reportMissingRecord: syncFileDownloadRequirement(descriptor, account: account, epoch: control.epoch).reportMissingRecord)
                    continue
                }
                throw error
            }
        }
    }

    private func syncFileDownloadRequirement(_ descriptor: ClipboardSyncFileDescriptor,
        account: ClipboardSyncAccount, epoch: UUID) throws -> (ancestryComplete: Bool, reportMissingRecord: Bool) {
        try syncFileRead { database in
            let nodes = try Row.fetchAll(database, sql: """
                SELECT version_id, parents FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [account.identifier, epoch.uuidString, descriptor.objectID.uuidString]).map { row -> ClipboardSyncVersionNode in
                    guard let id = UUID(uuidString: row["version_id"]) else { throw ClipboardSyncServiceError.corruptData }
                    return .init(id: id, parents: Set(try JSONDecoder().decode([UUID].self, from: row["parents"])))
                }
            guard ClipboardSyncVersionGraph.isComplete(nodes) else { return (false, true) }
            let heads = ClipboardSyncVersionGraph.heads(nodes)
            guard heads.count > 1, !heads.contains(descriptor.versionID) else { return (true, true) }
            // A complete conflict graph can retain a historical selection until
            // the user chooses a head. Its retired bytes are optional unless the
            // exact version was explicitly requested or pinned.
            let optionalFallback = try Bool.fetchOne(database, sql: """
                SELECT current_version_id = ?
                  AND NOT EXISTS(SELECT 1 FROM clipboard_sync_file_downloads
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ? AND authorized = 1)
                  AND NOT EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?)
                FROM clipboard_sync_file_selections WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [descriptor.versionID.uuidString,
                    account.identifier, epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString,
                    account.identifier, epoch.uuidString, descriptor.objectID.uuidString, descriptor.versionID.uuidString,
                    account.identifier, epoch.uuidString, descriptor.objectID.uuidString]) ?? false
            return (true, !optionalFallback)
        }
    }

    func syncFileIsReferenced(
        _ descriptor: ClipboardSyncFileDescriptor, account: ClipboardSyncAccount, epoch: UUID
    ) throws -> Bool {
        try requiredDatabase().read { database in
            try Bool.fetchOne(database, SQLRequest<Bool>(literal: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_file_members AS member
                    JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                    JOIN clipboard_entries AS entry ON entry.id = member.entry_id
                    WHERE member.account_id = \(account.identifier) AND member.epoch = \(epoch.uuidString) AND member.object_id = \(descriptor.objectID.uuidString)
                      AND (choice.current_version_id = \(descriptor.versionID.uuidString) OR EXISTS(
                        SELECT 1 FROM clipboard_sync_file_conflict_pins AS pin WHERE pin.account_id = member.account_id
                          AND pin.epoch = member.epoch AND pin.object_id = member.object_id
                          AND pin.version_id = \(descriptor.versionID.uuidString) AND pin.download_requested = 1)
                        OR EXISTS(SELECT 1 FROM clipboard_sync_file_auto_candidates AS candidate WHERE candidate.account_id = member.account_id
                          AND candidate.epoch = member.epoch AND candidate.object_id = member.object_id AND candidate.version_id = \(descriptor.versionID.uuidString)))
                      AND \(SQL(sql: Self.liveSyncFileMember)) AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier))))
                """)) ?? false
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
            // The legacy JSON envelope was only defined for bounded small
            // files. Larger files use segmentsV1, without an overall size cap.
            if descriptor.bodyFormat == nil, let size = descriptor.originalByteCount,
               size > Self.automaticSyncFileDownloadBytes {
                throw ClipboardSyncServiceError.corruptData
            }
            if descriptor.bodyFormat == .treeSegmentsV1 {
                guard let encoded = descriptor.encodedByteCount, let original = descriptor.originalByteCount,
                      encoded >= 13, encoded >= original, descriptor.kind != nil else { throw ClipboardSyncServiceError.corruptData }
            } else if descriptor.encodedByteCount != nil || descriptor.kind == .directory {
                throw ClipboardSyncServiceError.corruptData
            }
            if descriptor.bodyFormat != nil, let size = descriptor.streamByteCount {
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
