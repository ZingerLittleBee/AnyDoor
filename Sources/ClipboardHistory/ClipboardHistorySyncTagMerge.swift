import Foundation
import GRDB

struct ClipboardSyncTagMerge: Codable, Equatable, Sendable {
    let firstID: String
    let secondID: String
    let name: String
    let revision: ClipboardSyncTagRevision
}

extension ClipboardHistoryModule {
    public func prepareSyncTagMerge(sourceID: String, targetID: String) throws -> ClipboardHistorySyncTagMergePreview {
        try requiredDatabase().read { database in
            let settings = try syncSettings(in: database)
            guard settings.enabled, let accountID = settings.accountID, sourceID != targetID,
                  try canonicalSyncTagID(sourceID, accountID: accountID, in: database) == sourceID,
                  try canonicalSyncTagID(targetID, accountID: accountID, in: database) == targetID else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            let names = try String.fetchAll(database,
                sql: "SELECT display_name FROM clipboard_tag_definitions WHERE id IN (?, ?)", arguments: [sourceID, targetID])
            guard names.count == 2, names[0] == names[1] else { throw ClipboardHistoryModuleError.invalidTagName }
            let selected = Set(try selectedSyncTags(accountID: accountID, in: database).map(\.id))
            guard selected.contains(sourceID) || selected.contains(targetID) else { throw ClipboardHistoryModuleError.operationUnavailable }
            let count = try Int.fetchOne(database, SQLRequest<Int>(literal: """
                SELECT COUNT(*) FROM clipboard_entries AS entry
                WHERE \(sql: Self.syncEntryEligibility)
                  AND EXISTS (SELECT 1 FROM clipboard_entry_tags
                      WHERE entry_id = entry.id AND tag_id IN (\(sourceID), \(targetID)))
                  AND NOT (\(Self.syncEntryPublicationAuthority(accountID: accountID)))
                """)) ?? 0
            return ClipboardHistorySyncTagMergePreview(id: UUID(), sourceID: sourceID, targetID: targetID,
                displayName: names[0], newlyEligibleEntryCount: count,
                historyRevision: try Self.historyRevision(in: database), accountID: accountID)
        }
    }

    public func mergeSyncTags(_ preview: ClipboardHistorySyncTagMergePreview) async throws {
        _ = try await writableDatabase()
        let current = try prepareSyncTagMerge(sourceID: preview.sourceID, targetID: preview.targetID)
        guard current.accountID == preview.accountID, current.historyRevision == preview.historyRevision,
              current.newlyEligibleEntryCount == preview.newlyEligibleEntryCount,
              current.displayName == preview.displayName else { throw ClipboardHistoryModuleError.invalidConfirmation }
        try syncWrite { database in
            let merge = ClipboardSyncTagMerge(firstID: preview.sourceID, secondID: preview.targetID,
                name: preview.displayName, revision: try nextSyncTagRevision(in: database))
            try applySyncTagMerge(merge, accountID: preview.accountID, locallyConfirmed: true, in: database)
            try database.execute(sql: "INSERT INTO clipboard_sync_tag_merge_outbox(operation_id, account_id, content) VALUES (?, ?, ?)",
                arguments: [merge.revision.operationID, preview.accountID, try JSONEncoder().encode(merge)])
            try Self.bumpHistoryRevision(in: database)
            try Self.bumpSearchIndexGeneration(in: database)
        }
        publishMutation()
        if !syncSuspended { await retrySync() }
    }

    func canonicalSyncTagID(_ id: String, accountID: String, in database: Database) throws -> String {
        try String.fetchOne(database, sql: "SELECT canonical_id FROM clipboard_sync_tag_aliases WHERE account_id = ? AND alias_id = ?",
            arguments: [accountID, id]) ?? id
    }

    func stageSyncTagMerges(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, in database: Database) throws {
        for row in try Row.fetchAll(database, sql: "SELECT operation_id, content FROM clipboard_sync_tag_merge_outbox WHERE account_id = ?",
            arguments: [account.identifier]) {
            let merge = try JSONDecoder().decode(ClipboardSyncTagMerge.self, from: row["content"])
            let upload = try ClipboardSyncCodec.seal(.tagMerge(merge), account: account, control: control, key: key)
            try storeSyncUpload(upload, subjectID: min(merge.firstID, merge.secondID), account: account, in: database)
            try database.execute(sql: "DELETE FROM clipboard_sync_tag_merge_outbox WHERE operation_id = ?", arguments: [merge.revision.operationID])
        }
    }

    func applySyncTagMerge(_ merge: ClipboardSyncTagMerge, accountID: String,
                           locallyConfirmed: Bool, in database: Database) throws {
        guard !merge.firstID.isEmpty, !merge.secondID.isEmpty, merge.firstID != merge.secondID,
              !merge.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipboardSyncServiceError.corruptData }
        try observeSyncTagRevision(merge.revision, in: database)
        let first = try canonicalSyncTagID(merge.firstID, accountID: accountID, in: database)
        let second = try canonicalSyncTagID(merge.secondID, accountID: accountID, in: database)
        var members: Set<String> = [merge.firstID, merge.secondID, first, second]
        members.formUnion(try String.fetchAll(database,
            sql: "SELECT alias_id FROM clipboard_sync_tag_aliases WHERE account_id = ? AND canonical_id IN (?, ?)",
            arguments: [accountID, first, second]))
        guard let canonical = members.min() else { throw ClipboardSyncServiceError.corruptData }
        if !locallyConfirmed {
            // A shared identity merge is not this Mac's permission to move
            // retained history from another Apple Account into the new one.
            for member in members {
                try database.execute(sql: """
                    INSERT OR IGNORE INTO clipboard_sync_tag_blocked_entries(account_id, local_entry_id)
                    SELECT ?, membership.entry_id FROM clipboard_entry_tags AS membership
                    WHERE membership.tag_id = ?
                      AND EXISTS (SELECT 1 FROM clipboard_sync_entries AS former
                          WHERE former.local_entry_id = membership.entry_id AND former.account_id != ?)
                      AND NOT EXISTS (SELECT 1 FROM clipboard_entry_tags AS authorized
                          JOIN clipboard_sync_tags AS scope ON scope.tag_id = authorized.tag_id
                          WHERE authorized.entry_id = membership.entry_id AND scope.account_id = ?
                            AND scope.selected = 1 AND scope.locally_authorized = 1)
                    """, arguments: [accountID, member, accountID, accountID])
            }
        }
        let existing = try syncTagState(id: canonical, accountID: accountID, in: database)
        if existing.map({ $0.revision < merge.revision }) ?? true {
            let state = ClipboardSyncTagState(id: canonical, name: merge.name, selected: true, revision: merge.revision)
            try saveSyncTagState(state, accountID: accountID, pending: false, in: database)
            try database.execute(sql: """
                INSERT INTO clipboard_tag_definitions(id, display_name, display_order)
                VALUES (?, ?, COALESCE((SELECT MAX(display_order) + 1 FROM clipboard_tag_definitions), 0))
                ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name
                """, arguments: [canonical, merge.name])
            try database.execute(sql: """
                INSERT INTO clipboard_sync_tags(account_id, tag_id, selected, locally_authorized) VALUES (?, ?, 1, ?)
                ON CONFLICT(account_id, tag_id) DO UPDATE SET selected = 1,
                    locally_authorized = MAX(clipboard_sync_tags.locally_authorized, excluded.locally_authorized)
                """, arguments: [accountID, canonical, locallyConfirmed])
        }
        for member in members.sorted() {
            try database.execute(sql: """
                INSERT INTO clipboard_sync_tag_aliases(account_id, alias_id, canonical_id) VALUES (?, ?, ?)
                ON CONFLICT(account_id, alias_id) DO UPDATE SET canonical_id = excluded.canonical_id
                """, arguments: [accountID, member, canonical])
            guard member != canonical else { continue }
            try database.execute(sql: """
                INSERT OR IGNORE INTO clipboard_entry_tags(entry_id, tag_id)
                SELECT entry_id, ? FROM clipboard_entry_tags WHERE tag_id = ?
                """, arguments: [canonical, member])
            try database.execute(sql: "DELETE FROM clipboard_entry_tags WHERE tag_id = ?", arguments: [member])
            try database.execute(sql: "DELETE FROM clipboard_tag_definitions WHERE id = ?", arguments: [member])
            try database.execute(sql: "UPDATE clipboard_sync_tags SET selected = 0 WHERE account_id = ? AND tag_id = ?",
                arguments: [accountID, member])
        }
        if locallyConfirmed {
            try database.execute(sql: """
                DELETE FROM clipboard_sync_reset_exclusions WHERE account_id = ?
                  AND local_entry_id IN (SELECT entry_id FROM clipboard_entry_tags WHERE tag_id = ?)
                """, arguments: [accountID, canonical])
            try database.execute(sql: """
                DELETE FROM clipboard_sync_tag_blocked_entries WHERE account_id = ?
                  AND local_entry_id IN (SELECT entry_id FROM clipboard_entry_tags WHERE tag_id = ?)
                """, arguments: [accountID, canonical])
        }
        // The merge combines observed associations. A later explicit removal
        // wins over an old snapshot or merge replay by its persisted revision.
        for row in try Row.fetchAll(database, sql: "SELECT epoch, shared_id, local_entry_id FROM clipboard_sync_entries WHERE account_id = ?",
            arguments: [accountID]) {
            let localID: String = row["local_entry_id"]
            let sharedID: String = row["shared_id"]
            let epoch: String = row["epoch"]
            let present = try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_entry_tags WHERE entry_id = ? AND tag_id = ?)",
                arguments: [localID, canonical]) ?? false
            guard present else { continue }
            try database.execute(sql: """
                INSERT INTO clipboard_sync_memberships(account_id, epoch, shared_id, tag_id, present, counter, operation_id)
                VALUES (?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(account_id, epoch, shared_id, tag_id) DO UPDATE SET present = 1,
                    counter = excluded.counter, operation_id = excluded.operation_id, pending = 0
                WHERE clipboard_sync_memberships.counter < excluded.counter
                   OR (clipboard_sync_memberships.counter = excluded.counter AND clipboard_sync_memberships.operation_id < excluded.operation_id)
                """, arguments: [accountID, epoch, sharedID, canonical, merge.revision.counter, merge.revision.operationID])
        }
    }
}
