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
                    ClipboardHistorySyncTag(
                        id: row["id"], displayName: row["display_name"],
                        isSelected: selected.contains(row["id"]), eligibleEntryCount: row["eligible_count"]
                    )
                }
        }
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
