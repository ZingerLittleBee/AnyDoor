import Foundation
import GRDB

struct ClipboardSyncTextEditContent: Codable, Equatable, Sendable {
    let id: UUID
    let versionID: UUID
    let parents: [UUID]
    let text: String
    let editedAt: Date
}

/// Causality is independent of the payload. File versions can use the same
/// ancestry rules without introducing a second shared-entry lifecycle.
struct ClipboardSyncVersionNode: Sendable {
    let id: UUID
    let parents: Set<UUID>
}

enum ClipboardSyncVersionGraph {
    /// Validate a complete DAG in linear time without recursive stack growth.
    /// Missing nodes are permitted only during immutable event admission.
    static func isAcyclic(_ nodes: [ClipboardSyncVersionNode], requireAllParents: Bool = false) -> Bool {
        let known = Set(nodes.map(\.id))
        guard known.count == nodes.count else { return false }
        var counts: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        for node in nodes {
            if requireAllParents && !node.parents.isSubset(of: known) { return false }
            let parents = node.parents.intersection(known)
            counts[node.id] = parents.count
            for parent in parents { children[parent, default: []].append(node.id) }
        }
        var ready = counts.filter { $0.value == 0 }.map(\.key)
        var visited = 0
        while let next = ready.popLast() {
            visited += 1
            for child in children[next] ?? [] {
                counts[child, default: 0] -= 1
                if counts[child] == 0 { ready.append(child) }
            }
        }
        return visited == nodes.count
    }

    static func isComplete(_ nodes: [ClipboardSyncVersionNode]) -> Bool {
        !nodes.isEmpty && isAcyclic(nodes, requireAllParents: true)
    }

    static func heads(_ nodes: [ClipboardSyncVersionNode]) -> Set<UUID> {
        Set(nodes.map(\.id)).subtracting(nodes.flatMap(\.parents))
    }

    static func isComplete(_ id: UUID, nodes: [ClipboardSyncVersionNode]) -> Bool {
        let graph = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parents) })
        var visiting: Set<UUID> = []
        var complete: Set<UUID> = []
        func visit(_ candidate: UUID) -> Bool {
            if complete.contains(candidate) { return true }
            guard let parents = graph[candidate], visiting.insert(candidate).inserted else { return false }
            guard parents.allSatisfy({ visit($0) }) else { return false }
            visiting.remove(candidate)
            complete.insert(candidate)
            return true
        }
        return visit(id)
    }
}

struct ClipboardSyncTextEditBasis: Equatable, Sendable {
    let accountID: String
    let epoch: String
    let subjectID: String
    let versionID: UUID
}

public struct ClipboardHistoryTextVersion: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let editedAt: Date

    public init(id: UUID, text: String, editedAt: Date) {
        self.id = id
        self.text = text
        self.editedAt = editedAt
    }
}

/// The text and its causal basis are read together. Callers carry this value
/// through editing rather than silently rebasing an old draft onto new content.
public struct ClipboardHistoryTextEditPlan: Equatable, Sendable {
    public let entryID: ClipboardHistoryEntryID
    public let text: String
    public let versions: [ClipboardHistoryTextVersion]
    public var hasConflict: Bool { versions.count > 1 }
    let basis: ClipboardSyncTextEditBasis?
}

public struct ClipboardHistoryTextConflictResolution: Sendable {
    let plan: ClipboardHistoryTextEditPlan
    let versionID: UUID

    public init(plan: ClipboardHistoryTextEditPlan, versionID: UUID) {
        self.plan = plan
        self.versionID = versionID
    }
}

extension ClipboardHistoryModule {
    static func syncTextConflicts(entryIDs: [String], accountID: String?, in database: Database) throws -> Set<String> {
        guard !entryIDs.isEmpty, let accountID,
              let encoded = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [accountID]),
              let control = try JSONDecoder().decode(ClipboardSyncAccountState.self, from: encoded).control else { return [] }
        let values = Array(repeating: "(?)", count: entryIDs.count).joined(separator: ",")
        // Drive entry-leading lookups from the bounded page, even when a large
        // account makes an account-prefix scan look cheaper to the planner.
        let rows = try Row.fetchAll(database, sql: """
            WITH page_entries(entry_id) AS (VALUES \(values))
            SELECT shared.local_entry_id, shared.account_id, shared.epoch, shared.shared_id, shared.record_id, selection.version_id
            FROM page_entries CROSS JOIN clipboard_sync_entries AS shared INDEXED BY clipboard_sync_entries_local_entry
            LEFT JOIN clipboard_sync_version_selections AS selection
              ON selection.account_id = shared.account_id AND selection.epoch = shared.epoch
             AND selection.subject_id = shared.shared_id
            WHERE shared.local_entry_id = page_entries.entry_id AND shared.account_id = ? AND shared.epoch = ?
            """, arguments: StatementArguments(entryIDs + [accountID, control.epoch.uuidString]))
        var conflicts = Set<String>()
        var seenEntries = Set<String>()
        var subjects: [String: Bool] = [:]
        for row in rows {
            let entryID: String = row["local_entry_id"]
            guard seenEntries.insert(entryID).inserted else { continue }
            let basis = try syncTextEditBasis(row: row)
            let conflict: Bool
            if let cached = subjects[basis.subjectID] { conflict = cached }
            else {
                conflict = ClipboardSyncVersionGraph.heads(try syncVersionNodes(subjectID: basis.subjectID,
                    accountID: basis.accountID, epoch: basis.epoch, in: database)).count > 1
                subjects[basis.subjectID] = conflict
            }
            if conflict { conflicts.insert(entryID) }
        }
        return conflicts
    }

    public func textEditPlan(for entryID: ClipboardHistoryEntryID) throws -> ClipboardHistoryTextEditPlan {
        try requiredDatabase().read { database in
            guard try isLiveEntry(entryID.value.uuidString.lowercased(), at: now(), in: database),
                  try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM clipboard_items WHERE entry_id = ?",
                    arguments: [entryID.value.uuidString.lowercased()]) == 1,
                  let text = try String.fetchOne(database, sql: """
                    SELECT text_value FROM clipboard_representations
                    WHERE entry_id = ? AND type_identifier = 'public.utf8-plain-text' AND text_value IS NOT NULL
                    ORDER BY representation_index LIMIT 1
                    """, arguments: [entryID.value.uuidString.lowercased()]) else {
                throw ClipboardHistoryModuleError.invalidTextEdit
            }
            let basis = try Self.syncTextEditBasis(for: entryID, in: database)
            let versions: [ClipboardHistoryTextVersion]
            if let basis {
                let nodes = try Self.syncVersionNodes(subjectID: basis.subjectID, accountID: basis.accountID, epoch: basis.epoch, in: database)
                versions = try ClipboardSyncVersionGraph.heads(nodes).sorted { $0.uuidString < $1.uuidString }.map { id in
                    let content = try Self.syncTextVersion(id, basis: basis, in: database)
                    return ClipboardHistoryTextVersion(id: id, text: content.text, editedAt: content.editedAt)
                }
            } else { versions = [] }
            return ClipboardHistoryTextEditPlan(entryID: entryID, text: text, versions: versions, basis: basis)
        }
    }

    public func saveTextEdit(_ text: String, using plan: ClipboardHistoryTextEditPlan) async throws -> ClipboardHistoryMutationOutcome {
        let pool = try await writableDatabase()
        let result = try await editText(text, for: plan.entryID, in: pool, plan: plan)
        if result.didMutate { publishMutation() }
        return result.outcome
    }

    public func resolveTextConflict(_ request: ClipboardHistoryTextConflictResolution) async throws -> ClipboardHistoryMutationOutcome {
        _ = try await writableDatabase()
        let result = try syncWrite { database in
            guard let basis = request.plan.basis,
                  let current = try Self.syncTextEditBasis(for: request.plan.entryID, in: database),
                  current.accountID == basis.accountID, current.epoch == basis.epoch, current.subjectID == basis.subjectID else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            let nodes = try Self.syncVersionNodes(subjectID: basis.subjectID, accountID: basis.accountID, epoch: basis.epoch, in: database)
            let heads = ClipboardSyncVersionGraph.heads(nodes)
            guard heads.count > 1, heads == Set(request.plan.versions.map(\.id)), heads.contains(request.versionID),
                  heads.allSatisfy({ ClipboardSyncVersionGraph.isComplete($0, nodes: nodes) }) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            let chosen = try Self.syncTextVersion(request.versionID, basis: basis, in: database)
            let resolved = ClipboardSyncTextEditContent(id: chosen.id, versionID: UUID(),
                parents: heads.sorted { $0.uuidString < $1.uuidString }, text: chosen.text, editedAt: now())
            let result = try replaceText(chosen.text, for: request.plan.entryID, at: resolved.editedAt, in: database)
            guard result.outcome.didMutate else { return result }
            try Self.saveSyncTextVersion(resolved, accountID: basis.accountID, epoch: basis.epoch,
                origin: "local", recordID: nil, in: database)
            try Self.selectSyncVersion(resolved.versionID, subjectID: basis.subjectID,
                accountID: basis.accountID, epoch: basis.epoch, in: database)
            return try refreshingTextEditResult(result, entryID: request.plan.entryID, in: database)
        }
        cancelDerivedJobs(for: [request.plan.entryID.value.uuidString.lowercased()])
        await enqueueReclamation(for: result.payloadPaths)
        if result.outcome.didMutate { publishMutation() }
        return result.outcome.outcome
    }

    static func syncTextVersion(_ id: UUID, basis: ClipboardSyncTextEditBasis, in database: Database) throws -> ClipboardSyncTextEditContent {
        guard let data = try Data.fetchOne(database, sql: """
            SELECT content FROM clipboard_sync_versions WHERE account_id = ? AND epoch = ? AND subject_id = ? AND version_id = ? AND kind = 'text'
            """, arguments: [basis.accountID, basis.epoch, basis.subjectID, id.uuidString]) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return try JSONDecoder().decode(ClipboardSyncTextEditContent.self, from: data)
    }

    static func createSyncVersionSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_versions (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, subject_id TEXT NOT NULL,
                version_id TEXT NOT NULL, parents BLOB NOT NULL, kind TEXT NOT NULL,
                content BLOB NOT NULL, created_at DOUBLE NOT NULL,
                origin TEXT NOT NULL, record_id TEXT,
                PRIMARY KEY(account_id, epoch, subject_id, version_id)
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_version_selections (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, subject_id TEXT NOT NULL,
                version_id TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, subject_id)
            ) WITHOUT ROWID;
            """)
    }

    static func registerSyncTextRoot(
        _ entry: ClipboardSyncEntryContent, record: ClipboardSyncRemoteRecord,
        account: ClipboardSyncAccount, in database: Database
    ) throws {
        guard entry.items.count == 1,
              let text = entry.items[0].representations.compactMap({ representation -> String? in
                  if case .text("public.utf8-plain-text", let value) = representation { return value }
                  return nil
              }).first else { return }
        try registerSyncTextRoot(ClipboardSyncTextContent(id: entry.id, text: text,
            capturedAt: entry.capturedAt, sourceBundleID: entry.sourceBundleID,
            sourceDisplayName: entry.sourceDisplayName, sourceProvenance: entry.sourceProvenance,
            favorite: entry.favorite, tags: entry.tags), record: record, account: account, in: database)
    }

    static func registerSyncTextRoot(
        _ text: ClipboardSyncTextContent, record: ClipboardSyncRemoteRecord,
        account: ClipboardSyncAccount, in database: Database
    ) throws {
        let subjectID = text.id.uuidString.lowercased()
        let previousSelection = try String.fetchOne(database, sql: """
            SELECT version_id FROM clipboard_sync_version_selections WHERE account_id = ? AND epoch = ? AND subject_id = ?
            """, arguments: [account.identifier, record.epoch.uuidString, subjectID])
        let local = try Row.fetchOne(database, sql: """
            SELECT representation.text_value, entry.edited_at FROM clipboard_sync_entries AS shared
            JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            JOIN clipboard_representations AS representation ON representation.entry_id = entry.id
            WHERE shared.account_id = ? AND shared.epoch = ? AND shared.shared_id = ?
              AND representation.type_identifier = 'public.utf8-plain-text'
            ORDER BY representation.representation_index LIMIT 1
            """, arguments: [account.identifier, record.epoch.uuidString, subjectID])
        let content = ClipboardSyncTextEditContent(id: text.id, versionID: record.operationID,
            parents: [], text: text.text, editedAt: text.capturedAt)
        try saveSyncTextVersion(content, accountID: account.identifier, epoch: record.epoch.uuidString,
            origin: "root", recordID: record.recordID, in: database)
        try database.execute(sql: """
            INSERT OR IGNORE INTO clipboard_sync_version_selections(account_id, epoch, subject_id, version_id)
            VALUES (?, ?, ?, ?)
            """, arguments: [account.identifier, record.epoch.uuidString, text.id.uuidString.lowercased(), record.operationID.uuidString])
        // The old slice persisted edits only in the history entry. Recover its
        // initial parent from the immutable cloud operation, then journal the
        // differing local content instead of overwriting it during upgrade.
        if previousSelection == nil, let local, let localText: String = local["text_value"], localText != text.text {
            let editedAt: Double? = local["edited_at"]
            try recordSyncTextEdit(localText,
                basis: .init(accountID: account.identifier, epoch: record.epoch.uuidString,
                    subjectID: subjectID, versionID: record.operationID),
                at: Date(timeIntervalSince1970: editedAt ?? text.capturedAt.timeIntervalSince1970), in: database)
        }
    }

    static func needsSyncTextRootReplay(accountID: String, epoch: String, recordID: String? = nil, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT EXISTS (
                SELECT 1 FROM clipboard_sync_entries AS shared
                WHERE shared.account_id = ? AND shared.epoch = ?
                  AND (? IS NULL OR shared.record_id = ?)
                  AND (SELECT COUNT(*) FROM clipboard_items WHERE entry_id = shared.local_entry_id) = 1
                  AND EXISTS (SELECT 1 FROM clipboard_representations
                              WHERE entry_id = shared.local_entry_id AND type_identifier = 'public.utf8-plain-text')
                  AND NOT EXISTS (SELECT 1 FROM clipboard_sync_versions AS version
                                  WHERE version.account_id = shared.account_id AND version.epoch = shared.epoch
                                    AND version.subject_id = shared.shared_id AND version.record_id = shared.record_id)
            )
            """, arguments: [accountID, epoch, recordID, recordID]) ?? false
    }

    func needsSyncTextRootReplay(account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> Bool {
        try requiredDatabase().read {
            try Self.needsSyncTextRootReplay(accountID: account.identifier, epoch: control.epoch.uuidString, in: $0)
        }
    }

    static func syncTextEditBasis(for entryID: ClipboardHistoryEntryID, in database: Database) throws -> ClipboardSyncTextEditBasis? {
        guard let boundAccount = try String.fetchOne(database, sql: "SELECT account_id FROM clipboard_sync_settings WHERE id = 1"),
              let encoded = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [boundAccount]),
              let control = try JSONDecoder().decode(ClipboardSyncAccountState.self, from: encoded).control else { return nil }
        guard let row = try Row.fetchOne(database, sql: """
            SELECT shared.account_id, shared.epoch, shared.shared_id, shared.record_id, selection.version_id
            FROM clipboard_sync_entries AS shared
            LEFT JOIN clipboard_sync_version_selections AS selection
              ON selection.account_id = shared.account_id AND selection.epoch = shared.epoch
             AND selection.subject_id = shared.shared_id
            WHERE shared.local_entry_id = ? AND shared.account_id = ? AND shared.epoch = ?
            """, arguments: [entryID.value.uuidString.lowercased(), boundAccount, control.epoch.uuidString]) else { return nil }
        return try syncTextEditBasis(row: row)
    }

    private static func syncTextEditBasis(row: Row) throws -> ClipboardSyncTextEditBasis {
        let accountID: String = row["account_id"]
        let epoch: String = row["epoch"]
        let subjectID: String = row["shared_id"]
        if let value: String = row["version_id"], let versionID = UUID(uuidString: value) {
            return ClipboardSyncTextEditBasis(accountID: accountID, epoch: epoch, subjectID: subjectID, versionID: versionID)
        }
        // v14 mappings predate the journal. Their immutable initial operation
        // remains the parent even when its encrypted upload chunks were reclaimed.
        let recordID: String = row["record_id"]
        guard recordID.hasPrefix("v1-"), let versionID = UUID(uuidString: String(recordID.dropFirst(3))) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return ClipboardSyncTextEditBasis(accountID: accountID, epoch: epoch, subjectID: subjectID, versionID: versionID)
    }

    static func recordSyncTextEdit(
        _ text: String, basis: ClipboardSyncTextEditBasis, at date: Date, in database: Database
    ) throws {
        guard let subjectID = UUID(uuidString: basis.subjectID) else { throw ClipboardSyncServiceError.corruptData }
        let edit = ClipboardSyncTextEditContent(id: subjectID, versionID: UUID(),
            parents: [basis.versionID], text: text, editedAt: date)
        try saveSyncTextVersion(edit, accountID: basis.accountID, epoch: basis.epoch,
            origin: "local", recordID: nil, in: database)
        try selectSyncVersion(edit.versionID, subjectID: basis.subjectID,
            accountID: basis.accountID, epoch: basis.epoch, in: database)
    }

    static func saveSyncTextVersion(
        _ edit: ClipboardSyncTextEditContent, accountID: String, epoch: String,
        origin: String, recordID: String?, in database: Database
    ) throws {
        let content = try JSONEncoder().encode(edit)
        let subjectID = edit.id.uuidString.lowercased()
        let arguments: StatementArguments = [accountID, epoch, subjectID, edit.versionID.uuidString]
        if let previous = try Data.fetchOne(database, sql: """
            SELECT content FROM clipboard_sync_versions
            WHERE account_id = ? AND epoch = ? AND subject_id = ? AND version_id = ?
            """, arguments: arguments) {
            guard try JSONDecoder().decode(ClipboardSyncTextEditContent.self, from: previous) == edit else {
                throw ClipboardSyncServiceError.corruptData
            }
            return
        }
        try database.execute(sql: """
            INSERT INTO clipboard_sync_versions(account_id, epoch, subject_id, version_id, parents, kind,
                content, created_at, origin, record_id) VALUES (?, ?, ?, ?, ?, 'text', ?, ?, ?, ?)
            """, arguments: [accountID, epoch, subjectID, edit.versionID.uuidString,
                try JSONEncoder().encode(edit.parents), content, edit.editedAt.timeIntervalSince1970, origin, recordID])
    }

    static func selectSyncVersion(_ versionID: UUID, subjectID: String, accountID: String, epoch: String, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_version_selections(account_id, epoch, subject_id, version_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id, epoch, subject_id) DO UPDATE SET version_id = excluded.version_id
            """, arguments: [accountID, epoch, subjectID, versionID.uuidString])
    }

    static func syncVersionNodes(subjectID: String, accountID: String, epoch: String, in database: Database) throws -> [ClipboardSyncVersionNode] {
        try Row.fetchAll(database, sql: """
            SELECT version_id, parents FROM clipboard_sync_versions WHERE account_id = ? AND epoch = ? AND subject_id = ?
            """, arguments: [accountID, epoch, subjectID]).map { row in
                let value: String = row["version_id"]
                let parents: Data = row["parents"]
                guard let id = UUID(uuidString: value) else { throw ClipboardSyncServiceError.corruptData }
                return ClipboardSyncVersionNode(id: id, parents: Set(try JSONDecoder().decode([UUID].self, from: parents)))
            }
    }

    func stageSyncTextEdits(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, in database: Database) throws {
        let rows = try Row.fetchAll(database, SQLRequest<Row>(literal: """
            SELECT version.subject_id, version.version_id, version.content FROM clipboard_sync_versions AS version
            JOIN clipboard_sync_entries AS shared ON shared.account_id = version.account_id
                AND shared.epoch = version.epoch AND shared.shared_id = version.subject_id
            JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            WHERE version.account_id = \(account.identifier) AND version.epoch = \(control.epoch.uuidString)
              AND version.origin = 'local' AND version.record_id IS NULL
              AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier)))
            ORDER BY version.created_at, version.version_id
            """))
        for row in rows {
            guard try !Self.isSyncDeleted(row["subject_id"], accountID: account.identifier, epoch: control.epoch.uuidString, in: database) else { continue }
            let encoded: Data = row["content"]
            let edit = try JSONDecoder().decode(ClipboardSyncTextEditContent.self, from: encoded)
            let upload = try ClipboardSyncCodec.seal(.textEdit(edit), account: account, control: control, key: key, operationID: edit.versionID)
            try storeSyncUpload(upload, subjectID: row["subject_id"], account: account, in: database)
            try database.execute(sql: """
                UPDATE clipboard_sync_versions SET record_id = ?
                WHERE account_id = ? AND epoch = ? AND subject_id = ? AND version_id = ?
                """, arguments: [upload.record.recordID, account.identifier, control.epoch.uuidString,
                    edit.id.uuidString.lowercased(), edit.versionID.uuidString])
        }
    }

    static func receiveSyncTextEdit(_ edit: ClipboardSyncTextEditContent, record: ClipboardSyncRemoteRecord,
                                   account: ClipboardSyncAccount, in database: Database) throws {
        guard edit.versionID == record.operationID, !edit.parents.isEmpty,
              !edit.parents.contains(edit.versionID), Set(edit.parents).count == edit.parents.count,
              !edit.text.isEmpty, edit.text.utf8.count <= PasteboardSnapshot.maximumByteCount,
              edit.editedAt.timeIntervalSince1970.isFinite else { throw ClipboardSyncServiceError.corruptData }
        try saveSyncTextVersion(edit, accountID: account.identifier, epoch: record.epoch.uuidString,
            origin: "remote", recordID: record.recordID, in: database)
    }

    func reconcileSyncTextVersions(subjectID: String, accountID: String, epoch: String, in database: Database) throws {
        let nodes = try Self.syncVersionNodes(subjectID: subjectID, accountID: accountID, epoch: epoch, in: database)
        let heads = ClipboardSyncVersionGraph.heads(nodes)
        guard heads.count == 1, let head = heads.first, ClipboardSyncVersionGraph.isComplete(head, nodes: nodes),
              let row = try Row.fetchOne(database, sql: """
                SELECT shared.local_entry_id, selection.version_id FROM clipboard_sync_entries AS shared
                LEFT JOIN clipboard_sync_version_selections AS selection
                  ON selection.account_id = shared.account_id AND selection.epoch = shared.epoch AND selection.subject_id = shared.shared_id
                WHERE shared.account_id = ? AND shared.epoch = ? AND shared.shared_id = ?
                """, arguments: [accountID, epoch, subjectID]) else { return }
        let selected: String? = row["version_id"]
        guard selected != head.uuidString else { return }
        let localID: String = row["local_entry_id"]
        guard let entryID = UUID(uuidString: localID), let data = try Data.fetchOne(database, sql: """
            SELECT content FROM clipboard_sync_versions WHERE account_id = ? AND epoch = ? AND subject_id = ? AND version_id = ?
            """, arguments: [accountID, epoch, subjectID, head.uuidString]) else { throw ClipboardSyncServiceError.corruptData }
        let edit = try JSONDecoder().decode(ClipboardSyncTextEditContent.self, from: data)
        _ = try replaceText(edit.text, for: .init(entryID), at: edit.editedAt, in: database)
        // Removed encrypted payloads remain safe orphans until normal maintenance.
        try Self.selectSyncVersion(head, subjectID: subjectID, accountID: accountID, epoch: epoch, in: database)
    }
}
