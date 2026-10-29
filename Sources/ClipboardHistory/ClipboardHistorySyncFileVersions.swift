import Foundation
import GRDB

extension ClipboardHistoryModule {
    func syncFileSelection(objectID: UUID) throws -> ClipboardSyncFileSelection? {
        try requiredDatabase().read { database in
            guard let context = try syncFileContext(in: database),
                  let selection = try Row.fetchOne(database, sql: """
                    SELECT current_version_id, complete_version_id FROM clipboard_sync_file_selections
                    WHERE account_id = ? AND epoch = ? AND object_id = ?
                    """, arguments: [context.account.identifier, context.control.epoch.uuidString, objectID.uuidString]) else { return nil }
            let rows = try Row.fetchAll(database, sql: """
                SELECT version_id, descriptor, parents, local_path, local_bookmark, local_identity, transfer_state
                FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [context.account.identifier, context.control.epoch.uuidString, objectID.uuidString])
            let current: String = selection["current_version_id"]
            let completed: String? = selection["complete_version_id"]
            guard let latest = rows.first(where: { ($0["version_id"] as String) == current }) else { return nil }
            let nonHeads = try Set(rows.flatMap { try JSONDecoder().decode([UUID].self, from: $0["parents"]) })
            let heads = try rows.filter { row in
                guard let id = UUID(uuidString: row["version_id"]) else { return false }
                return !nonHeads.contains(id)
            }.map { try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: $0["descriptor"]) }
            let complete: ClipboardSyncVerifiedFileVersion?
            if let row = rows.first(where: { ($0["version_id"] as String) == completed }),
               (row["transfer_state"] as String) == "complete",
               let bookmark: Data = row["local_bookmark"], let identity: Data = row["local_identity"],
               let url = try? ClipboardSyncFileIO.resolve(bookmark: bookmark, identity: identity) {
                complete = .init(descriptor: try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"]),
                    parents: try JSONDecoder().decode([UUID].self, from: row["parents"]), url: url, identity: identity, bookmark: bookmark)
            } else { complete = nil }
            return .init(latest: try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: latest["descriptor"]),
                complete: complete, heads: heads)
        }
    }

    /// Explicitly retry reading this tracked file's saved content. Observers use
    /// publishFileVersion with their actual edited base instead of rebasing it.
    public func refreshSyncFile(entryID: ClipboardHistoryEntryID, objectID: UUID) async throws {
        let source = try syncFileRead { database in
            guard let context = try syncFileContext(in: database),
                  let row = try Row.fetchOne(database, sql: """
                    SELECT version.version_id, version.local_bookmark, version.local_identity
                    FROM clipboard_sync_file_members AS member
                    JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                    JOIN clipboard_sync_file_versions AS version ON version.account_id = member.account_id
                      AND version.epoch = member.epoch AND version.object_id = member.object_id
                      AND version.version_id = COALESCE(choice.complete_version_id, member.version_id)
                    WHERE member.account_id = ? AND member.epoch = ? AND member.entry_id = ? AND member.object_id = ?
                    """, arguments: [context.account.identifier, context.control.epoch.uuidString,
                        entryID.value.uuidString.lowercased(), objectID.uuidString]),
                  let bookmark: Data = row["local_bookmark"], let identity: Data = row["local_identity"],
                  let parent = UUID(uuidString: row["version_id"]) else { throw ClipboardHistoryModuleError.operationUnavailable }
            let url = try ClipboardSyncFileIO.resolve(bookmark: bookmark, identity: identity)
            let origin = try Self.linkedLocationSources(accountID: context.account.identifier,
                epoch: context.control.epoch, in: database).first { $0.objectID == objectID && $0.identity == identity && $0.url == url }
            if origin == nil, try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_linked_locations
                  WHERE account_id = ? AND epoch = ? AND object_id = ? AND identity = ? AND path = ?)
                """, arguments: [context.account.identifier, context.control.epoch.uuidString,
                    objectID.uuidString, identity, url.path]) == true {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            return (url, identity, origin?.baseVersionID ?? parent, origin)
        }
        _ = try await publishFileVersion(sourceURL: source.0, objectID: objectID, parents: [source.2],
            expectedSourceIdentity: source.1, origin: source.3)
        await retrySync()
    }

    func publishFileVersion(sourceURL: URL, objectID: UUID, parents: [UUID], expectedSourceIdentity: Data,
        origin: ClipboardLinkedLocationSource? = nil) async throws -> UUID {
        let generation = syncGeneration
        try admitSync(generation)
        guard let services = syncServices,
              let context = try syncFileRead({ try syncFileContext(in: $0) }) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let account = context.account
        let control = context.control
        try await admitSyncFilePublication(generation, account: account, control: control, services: services)
        guard !parents.isEmpty, Set(parents).count == parents.count,
              try syncFileCanPublish(objectID: objectID, account: account, control: control, parents: parents),
              let displayName = try syncFileSelection(objectID: objectID)?.latest.displayName else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        guard let key = try await services.keys.load(account: account, keyID: control.keyID), key.count == 32,
              ClipboardSyncCodec.check(key: key, account: account, keyID: control.keyID) == control.keyCheck else {
            throw ClipboardSyncServiceError.keyUnavailable
        }
        try await admitSyncFilePublication(generation, account: account, control: control, services: services)
        let versionID = UUID()
        let prepared = try await prepareFileVersion(sourceURL: sourceURL, objectID: objectID, versionID: versionID,
            publicationID: UUID(), parents: parents, expectedSourceIdentity: expectedSourceIdentity,
            displayName: displayName, account: account, control: control, key: key)
        var stored = false
        defer { if !stored { try? FileManager.default.removeItem(at: prepared.uploadDirectory) } }
        let observedDigest: Data?
        if let origin {
            let inspection = Task.detached(priority: .utility) {
                try? ClipboardLinkedFileIO.inspect(origin.url, expectedIdentity: origin.identity).digest
            }
            observedDigest = await withTaskCancellationHandler { await inspection.value } onCancel: { inspection.cancel() }
        } else { observedDigest = nil }
        try await admitSyncFilePublication(generation, account: account, control: control, services: services)
        guard try syncFileCanPublish(objectID: objectID, account: account, control: control, parents: parents) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        try syncWrite { database in
            guard try syncFileCanPublish(objectID: objectID, account: account, control: control, parents: parents, in: database) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            if let origin {
                guard parents == [origin.baseVersionID], origin.objectID == objectID,
                      let current = try Self.linkedLocationSources(accountID: account.identifier,
                        epoch: control.epoch, id: origin.id, in: database).first,
                      current.revision == origin.revision, current.identity == origin.identity,
                      current.url == origin.url, current.baseVersionID == origin.baseVersionID,
                      current.baseDigest == origin.baseDigest, !current.hasPendingApplication else {
                    throw POSIXError(.ESTALE)
                }
            }
            try storePreparedFileVersion(prepared, account: account, control: control, in: database)
            if let origin {
                guard let digest = prepared.descriptor.contentDigest else { throw ClipboardSyncServiceError.corruptData }
                let state: ClipboardHistoryLinkedFileLocationState = observedDigest.map {
                    $0 == digest ? .pendingUpload : .localChanges
                } ?? .unavailable
                // Publication and the origin's adopted base share one authority check.
                // A pause or reassociation during freezing cannot publish an orphaned edit.
                try database.execute(sql: """
                    UPDATE clipboard_sync_linked_locations SET base_version_id = ?, base_digest = ?,
                      state = ?, pending_version_id = ?, observed_digest = ? WHERE id = ?
                    """, arguments: [versionID.uuidString, digest, state.rawValue, versionID.uuidString,
                        observedDigest, origin.id.uuidString])
                try completeSyncFileWork(.linkedLocation(origin.id), account: account, control: control, in: database)
            }
            try Self.bumpHistoryRevision(in: database)
            try Self.bumpSearchIndexGeneration(in: database)
        }
        stored = true
        publishMutation()
        return versionID
    }

    func syncFileContext(in database: Database) throws -> (account: ClipboardSyncAccount, control: ClipboardSyncControl)? {
        guard let accountID = try syncSettings(in: database).accountID,
              let data = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [accountID]) else { return nil }
        let state = try JSONDecoder().decode(ClipboardSyncAccountState.self, from: data)
        guard let control = state.control else { return nil }
        return (state.account, control)
    }

    private func syncFileCanPublish(objectID: UUID, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, parents: [UUID]) throws -> Bool {
        try requiredDatabase().read { try syncFileCanPublish(objectID: objectID, account: account, control: control, parents: parents, in: $0) }
    }

    private func syncFileCanPublish(objectID: UUID, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, parents: [UUID], in database: Database) throws -> Bool {
        guard control.phase == "active", try Bool.fetchOne(database, SQLRequest<Bool>(literal: """
            SELECT EXISTS (SELECT 1 FROM clipboard_sync_file_members AS member
                JOIN clipboard_entries AS entry ON entry.id = member.entry_id
                JOIN clipboard_representations AS representation ON representation.entry_id = member.entry_id
                  AND representation.item_index = member.item_index AND representation.representation_index = member.representation_index
                WHERE member.account_id = \(account.identifier) AND member.epoch = \(control.epoch.uuidString)
                  AND member.object_id = \(objectID.uuidString) AND representation.kind = 'fileReference'
                  AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier))))
            """)) == true else { return false }
        for parent in parents {
            guard try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_file_versions
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?)
                """, arguments: [account.identifier, control.epoch.uuidString, objectID.uuidString, parent.uuidString]) == true else { return false }
        }
        return true
    }

    func importSyncFileVersion(_ version: ClipboardSyncFileVersionContent, account: ClipboardSyncAccount,
        record: ClipboardSyncRemoteRecord, in database: Database) throws {
        guard version.descriptor.state == .available, !version.parents.isEmpty,
              !version.parents.contains(version.descriptor.versionID), Set(version.parents).count == version.parents.count else {
            throw ClipboardSyncServiceError.corruptData
        }
        try validateSyncFileDescriptor(version.descriptor, epoch: record.epoch, keyID: record.keyID)
        try storeSyncFileDescriptor(version.descriptor, account: account, epoch: record.epoch,
            localPath: nil, bookmark: nil, identity: nil, transferState: "pending", parents: version.parents, publicationRecordID: record.recordID, in: database)
    }

    static func reduceSyncFileVersions(descriptor: ClipboardSyncFileDescriptor, accountID: String,
        epoch: UUID, complete: Bool, in database: Database) throws {
        let scope: StatementArguments = [accountID, epoch.uuidString, descriptor.objectID.uuidString]
        try database.execute(sql: """
            INSERT INTO clipboard_sync_file_selections(account_id, epoch, object_id, current_version_id, complete_version_id)
            VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id, epoch, object_id) DO NOTHING
            """, arguments: [accountID, epoch.uuidString, descriptor.objectID.uuidString,
                descriptor.versionID.uuidString, complete ? descriptor.versionID.uuidString : nil])
        let rows = try Row.fetchAll(database, sql: """
            SELECT version_id, parents FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ?
            """, arguments: scope)
        let nodes = try rows.map { row -> ClipboardSyncVersionNode in
            guard let id = UUID(uuidString: row["version_id"]) else { throw ClipboardSyncServiceError.corruptData }
            return .init(id: id, parents: Set(try JSONDecoder().decode([UUID].self, from: row["parents"])))
        }
        let heads = ClipboardSyncVersionGraph.heads(nodes)
        if heads.count == 1, let head = heads.first,
           ClipboardSyncVersionGraph.isComplete(nodes) {
            try database.execute(sql: """
                UPDATE clipboard_sync_file_selections SET current_version_id = ?
                WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [head.uuidString, accountID, epoch.uuidString, descriptor.objectID.uuidString])
        }
        if complete {
            try database.execute(sql: """
                UPDATE clipboard_sync_file_selections SET complete_version_id = ?
                WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [descriptor.versionID.uuidString, accountID, epoch.uuidString, descriptor.objectID.uuidString])
        }
    }

    /// Missing parents can arrive later. A cycle can never become valid through
    /// later delivery, so reject it before it influences any selected version.
    static func validateSyncFileAncestry(accountID: String, epoch: UUID, objectID: UUID, in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: """
            SELECT version_id, parents FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ?
            """, arguments: [accountID, epoch.uuidString, objectID.uuidString])
        var graph: [UUID: Set<UUID>] = [:]
        for row in rows {
            guard let id = UUID(uuidString: row["version_id"]) else { throw ClipboardSyncServiceError.corruptData }
            graph[id] = Set(try JSONDecoder().decode([UUID].self, from: row["parents"]))
        }
        guard ClipboardSyncVersionGraph.isAcyclic(graph.map { .init(id: $0.key, parents: $0.value) }) else {
            throw ClipboardSyncServiceError.corruptData
        }
    }
}
