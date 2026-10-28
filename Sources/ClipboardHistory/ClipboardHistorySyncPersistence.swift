import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func syncTags() throws -> [ClipboardHistorySyncTag] {
        let database = try requiredDatabase()
        return try database.read { database in
            let accountID = try syncSettings(in: database).accountID ?? ""
            let selected = Set(try selectedSyncTags(accountID: accountID, in: database).map(\.id))
            return try Row.fetchAll(database, sql: """
                SELECT definition.id, definition.display_name,
                       (SELECT COUNT(*) FROM clipboard_entry_tags AS membership
                        JOIN clipboard_entries AS entry ON entry.id = membership.entry_id
                        WHERE membership.tag_id = definition.id
                          AND \(Self.syncEntryEligibility)) AS eligible_count
                FROM clipboard_tag_definitions AS definition
                ORDER BY definition.display_order, definition.id
                """).map { row in
                    try ClipboardHistorySyncTag(
                        id: row["id"], displayName: row["display_name"],
                        isSelected: selected.contains(row["id"]), eligibleEntryCount: row["eligible_count"],
                        canDeselect: !selected.contains(row["id"]) || canDeselectSyncTag(row["id"], accountID: accountID, in: database),
                        requiresLocalAuthorization: selected.contains(row["id"]) && syncTagRequiresLocalAuthorization(
                            row["id"], accountID: accountID, in: database)
                    )
                }
        }
    }

    private func syncTagRequiresLocalAuthorization(_ tagID: String, accountID: String, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT EXISTS (SELECT 1 FROM clipboard_entry_tags AS membership
                JOIN clipboard_sync_tags AS selected ON selected.tag_id = membership.tag_id
                WHERE membership.tag_id = ? AND selected.account_id = ?
                  AND EXISTS (SELECT 1 FROM clipboard_sync_entries AS former
                      WHERE former.local_entry_id = membership.entry_id AND former.account_id != selected.account_id)
                  AND (selected.locally_authorized = 0 OR EXISTS (
                      SELECT 1 FROM clipboard_sync_tag_blocked_entries AS blocked
                      WHERE blocked.account_id = selected.account_id AND blocked.local_entry_id = membership.entry_id)))
            """, arguments: [tagID, accountID]) ?? false
    }

    /// Until withdrawal is available, changing selection must leave every
    /// potentially shared entry eligible through another selected tag.
    func canDeselectSyncTag(_ tagID: String, accountID: String, in database: Database) throws -> Bool {
        try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM clipboard_entry_tags AS membership
            WHERE membership.tag_id = ? AND NOT EXISTS (
                SELECT 1 FROM clipboard_entry_tags AS other
                JOIN clipboard_sync_tags AS selected ON selected.tag_id = other.tag_id
                WHERE other.entry_id = membership.entry_id AND other.tag_id != membership.tag_id
                  AND selected.account_id = ? AND selected.selected = 1)
            """, arguments: [tagID, accountID]) == 0
    }

    /// Publication authority for the fixed `entry` SQL alias. Values remain
    /// bound inside the literal so callers never manage this predicate's slots.
    static func syncEntryPublicationAuthority(accountID: String) -> SQL {
        """
        NOT EXISTS (SELECT 1 FROM clipboard_sync_preserved_edits WHERE local_entry_id = entry.id)
        AND NOT EXISTS (SELECT 1 FROM clipboard_sync_entries AS shared
            JOIN clipboard_sync_withdrawals AS withdrawal ON withdrawal.account_id = shared.account_id
                AND withdrawal.epoch = shared.epoch AND withdrawal.shared_id = shared.shared_id
            WHERE shared.local_entry_id = entry.id AND shared.account_id = \(accountID) AND withdrawal.withdrawn = 1)
        AND NOT EXISTS (SELECT 1 FROM clipboard_sync_entries AS shared
            JOIN clipboard_sync_deletions AS deleted ON deleted.account_id = shared.account_id
                AND deleted.epoch = shared.epoch AND deleted.shared_id = shared.shared_id
            WHERE shared.local_entry_id = entry.id AND shared.account_id = \(accountID))
        AND NOT EXISTS (SELECT 1 FROM clipboard_sync_reset_exclusions AS retired
                    WHERE retired.account_id = \(accountID) AND retired.local_entry_id = entry.id)
        AND NOT EXISTS (SELECT 1 FROM clipboard_sync_tag_blocked_entries AS blocked
                    WHERE blocked.account_id = \(accountID) AND blocked.local_entry_id = entry.id)
        AND EXISTS (SELECT 1 FROM clipboard_entry_tags AS membership
            JOIN clipboard_sync_tags AS selected ON selected.tag_id = membership.tag_id
            WHERE membership.entry_id = entry.id AND selected.account_id = \(accountID) AND selected.selected = 1
              AND (selected.locally_authorized = 1 OR NOT EXISTS (
                SELECT 1 FROM clipboard_sync_entries AS former
                WHERE former.local_entry_id = entry.id AND former.account_id != selected.account_id)))
        """
    }

    /// Admission is for the whole entry, never a filtered representation subset.
    static let syncEntryEligibility = """
        NOT EXISTS (SELECT 1 FROM clipboard_sync_preserved_edits WHERE local_entry_id = entry.id)
        AND EXISTS (SELECT 1 FROM clipboard_items WHERE entry_id = entry.id)
        AND NOT EXISTS (SELECT 1 FROM clipboard_items AS item
            WHERE item.entry_id = entry.id AND NOT EXISTS (
                SELECT 1 FROM clipboard_representations AS representation
                WHERE representation.entry_id = item.entry_id AND representation.item_index = item.item_index))
        AND NOT EXISTS (SELECT 1 FROM clipboard_representations
            WHERE entry_id = entry.id AND kind NOT IN ('text', 'richText', 'bitmap', 'color', 'fileReference'))
        """
}
