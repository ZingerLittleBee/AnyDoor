import Foundation
import GRDB

struct ClipboardSyncConflictVersion: Sendable {
    let descriptor: ClipboardSyncFileDescriptor
    let parents: [UUID]
    let path: String?
    let identity: Data?
    var retainedPlanID: UUID? = nil
    var prepared: ClipboardSyncPreparedFileVersion? = nil
}

struct ClipboardSyncFileConflictBasis: Sendable {
    let account: ClipboardSyncAccount
    let control: ClipboardSyncControl
    let versions: [ClipboardSyncConflictVersion]
    let locations: [ClipboardLinkedLocationSource]
    let retainedPlanIDs: [UUID]

    var nodes: [ClipboardSyncVersionNode] { versions.map { .init(id: $0.descriptor.versionID, parents: Set($0.parents)) } }
    var heads: [UUID] { ClipboardSyncVersionGraph.heads(nodes).sorted { $0.uuidString < $1.uuidString } }
}

extension ClipboardHistoryModule {
    static func createSyncFileConflictSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_file_conflict_plans (
                id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL,
                epoch TEXT NOT NULL, object_id TEXT NOT NULL, snapshot BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_file_resolutions (
                plan_id TEXT PRIMARY KEY NOT NULL REFERENCES clipboard_sync_file_conflict_plans(id),
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, object_id TEXT NOT NULL,
                phase TEXT NOT NULL, journal BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE UNIQUE INDEX clipboard_sync_file_resolution_active
                ON clipboard_sync_file_resolutions(account_id, epoch, object_id)
                WHERE phase IN ('preparing', 'staged');
            CREATE TABLE clipboard_sync_file_conflict_pins (
                plan_id TEXT NOT NULL REFERENCES clipboard_sync_file_conflict_plans(id),
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, object_id TEXT NOT NULL, version_id TEXT NOT NULL,
                download_requested INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(plan_id, version_id)
            ) WITHOUT ROWID;
            """)
    }

    public func fileConflictPlan(entryID: ClipboardHistoryEntryID, objectID: UUID) async throws -> ClipboardHistoryFileConflictPlan {
        let generation = syncGeneration
        let basis = try linkedRead { try fileConflictBasis(entryID: entryID, objectID: objectID, in: $0) }
        let inspection = Task.detached(priority: .userInitiated) {
            let locations = basis.locations.map { source in
                (source.id, try? ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: source.identity))
            }
            let versions = basis.versions.filter { basis.heads.contains($0.descriptor.versionID) }.map { version in
                let proof = version.path.flatMap { path in
                    version.identity.flatMap { try? ClipboardLinkedFileIO.inspect(URL(fileURLWithPath: path), expectedIdentity: $0) }
                }
                return (version.descriptor.versionID, proof)
            }
            return (locations, versions)
        }
        let inspected = await withTaskCancellationHandler { await inspection.value } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        guard generation == syncGeneration else { throw ClipboardHistoryModuleError.operationUnavailable }
        let saved = Dictionary(uniqueKeysWithValues: inspected.0)
        let versionProofs = Dictionary(uniqueKeysWithValues: inspected.1)
        let locations = basis.locations.map { location in
            let proof = saved[location.id] ?? nil
            return ClipboardSyncFileConflictLocation(id: location.id, path: location.url.path, identity: location.identity, revision: location.revision,
                baseVersionID: location.baseVersionID, baseDigest: location.baseDigest, state: location.state.rawValue,
                savedDigest: proof?.digest, byteCount: proof?.byteCount)
        }
        var candidates = locations.compactMap { location -> ClipboardHistoryFileConflictCandidate? in
            guard let digest = location.savedDigest, digest != location.baseDigest else { return nil }
            return .init(id: .localLocation(location.id), originalByteCount: location.byteCount,
                availability: .available, localURL: URL(fileURLWithPath: location.path))
        }
        for id in basis.heads {
            guard let version = basis.versions.first(where: { $0.descriptor.versionID == id }) else { continue }
            let proof = versionProofs[id] ?? nil
            let available = proof?.digest == version.descriptor.contentDigest && proof?.byteCount == version.descriptor.originalByteCount && proof != nil
            candidates.append(.init(id: .version(id), originalByteCount: version.descriptor.originalByteCount,
                availability: available ? .available : version.descriptor.state == .available ? .requiresDownload : .unavailable,
                localURL: available ? proof?.url : nil))
        }
        let nodes = basis.nodes
        let complete = ClipboardSyncVersionGraph.isComplete(nodes)
        guard candidates.count > 1 || !complete || basis.locations.contains(where: { $0.state == .conflict }) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let snapshot = ClipboardSyncFileConflictSnapshot(accountID: basis.account.identifier, epoch: basis.control.epoch,
            keyID: basis.control.keyID, entryID: entryID.value, objectID: objectID, heads: basis.heads, locations: locations)
        let id = UUID()
        try syncWrite { database in
            let current = try fileConflictBasis(entryID: entryID, objectID: objectID, in: database)
            guard current.account == basis.account, current.control.epoch == basis.control.epoch,
                  current.control.keyID == basis.control.keyID, current.heads == basis.heads,
                  Self.conflictLocationFactsMatch(locations, sources: current.locations) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_conflict_plans(id, account_id, epoch, object_id, snapshot)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, basis.account.identifier, basis.control.epoch.uuidString,
                    objectID.uuidString, try JSONEncoder().encode(snapshot)])
        }
        return .init(id: id, entryID: entryID, objectID: objectID,
            displayName: basis.versions.first?.descriptor.displayName ?? "", candidates: candidates, ancestryComplete: complete)
    }

    func fileConflictBasis(entryID: ClipboardHistoryEntryID, objectID: UUID, in database: Database) throws -> ClipboardSyncFileConflictBasis {
        guard let context = try syncFileContext(in: database),
              try Bool.fetchOne(database, SQLRequest<Bool>(literal: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_members AS member
                  JOIN clipboard_entries AS entry ON entry.id = member.entry_id
                  WHERE member.account_id = \(context.account.identifier) AND member.epoch = \(context.control.epoch.uuidString)
                    AND member.entry_id = \(entryID.value.uuidString.lowercased()) AND member.object_id = \(objectID.uuidString)
                    AND \(SQL(sql: Self.liveSyncFileMember))
                    AND (\(Self.syncEntryPublicationAuthority(accountID: context.account.identifier))))
                """)) == true else { throw ClipboardHistoryModuleError.operationUnavailable }
        var versions = try Row.fetchAll(database, sql: """
            SELECT descriptor, parents, local_path, local_identity FROM clipboard_sync_file_versions
            WHERE account_id = ? AND epoch = ? AND object_id = ? ORDER BY version_id
            """, arguments: [context.account.identifier, context.control.epoch.uuidString, objectID.uuidString]).map { row in
                ClipboardSyncConflictVersion(descriptor: try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"]),
                    parents: try JSONDecoder().decode([UUID].self, from: row["parents"]), path: row["local_path"], identity: row["local_identity"])
            }
        let retained = try Row.fetchAll(database, sql: """
            SELECT plan_id, journal FROM clipboard_sync_file_resolutions
            WHERE account_id = ? AND epoch = ? AND object_id = ? AND phase = 'needsReview' ORDER BY plan_id
            """, arguments: [context.account.identifier, context.control.epoch.uuidString, objectID.uuidString])
        for row in retained {
            guard let id = UUID(uuidString: row["plan_id"]) else { throw ClipboardSyncServiceError.corruptData }
            let journal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: row["journal"])
            for prepared in journal.prepared where prepared.descriptor.versionID != journal.resultID
                && !versions.contains(where: { $0.descriptor.versionID == prepared.descriptor.versionID }) {
                versions.append(.init(descriptor: prepared.descriptor, parents: prepared.parents,
                    path: prepared.sourceURL.path, identity: prepared.identity, retainedPlanID: id, prepared: prepared))
            }
        }
        let locations = try Self.linkedLocationSources(accountID: context.account.identifier, epoch: context.control.epoch, in: database)
            .filter { $0.objectID == objectID }
        return .init(account: context.account, control: context.control, versions: versions, locations: locations,
            retainedPlanIDs: retained.compactMap { UUID(uuidString: $0["plan_id"]) })
    }

    static func conflictLocationFactsMatch(_ expected: [ClipboardSyncFileConflictLocation], sources: [ClipboardLinkedLocationSource]) -> Bool {
        guard expected.count == sources.count else { return false }
        return expected.allSatisfy { location in
            sources.contains { source in
                source.id == location.id && source.identity == location.identity && source.url.path == location.path
                    && source.baseVersionID == location.baseVersionID && source.baseDigest == location.baseDigest
                    && source.state.rawValue == location.state && source.revision == location.revision
            }
        }
    }

    static func syncFileHasConflict(objectID: UUID, accountID: String, epoch: String, in database: Database) throws -> Bool {
        let rows = try Row.fetchAll(database, sql: """
            SELECT version_id, parents FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ?
            """, arguments: [accountID, epoch, objectID.uuidString])
        let nodes = try rows.map { row -> ClipboardSyncVersionNode in
            guard let id = UUID(uuidString: row["version_id"]) else { throw ClipboardSyncServiceError.corruptData }
            return .init(id: id, parents: Set(try JSONDecoder().decode([UUID].self, from: row["parents"])))
        }
        if ClipboardSyncVersionGraph.heads(nodes).count > 1 || !ClipboardSyncVersionGraph.isComplete(nodes) { return true }
        return try Bool.fetchOne(database, sql: """
            SELECT EXISTS(SELECT 1 FROM clipboard_sync_linked_locations WHERE account_id = ? AND epoch = ? AND object_id = ? AND state = 'conflict')
              OR EXISTS(SELECT 1 FROM clipboard_sync_file_resolutions WHERE account_id = ? AND epoch = ? AND object_id = ? AND phase = 'needsReview')
            """, arguments: [accountID, epoch, objectID.uuidString, accountID, epoch, objectID.uuidString]) ?? false
    }
}
