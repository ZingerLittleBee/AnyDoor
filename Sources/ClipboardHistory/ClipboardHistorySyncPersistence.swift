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
                          AND \(Self.syncPlainTextEligibility)) AS eligible_count
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

    /// The first sync slice accepts a complete single-item plain-text entry.
    /// Expanding content support must preserve this whole-entry boundary.
    static let syncPlainTextEligibility = """
        (SELECT COUNT(*) FROM clipboard_items WHERE entry_id = entry.id) = 1
        AND (SELECT COUNT(*) FROM clipboard_representations WHERE entry_id = entry.id) = 1
        AND EXISTS (SELECT 1 FROM clipboard_representations
                    WHERE entry_id = entry.id AND kind = 'text'
                      AND type_identifier = 'public.utf8-plain-text')
        AND NOT EXISTS (SELECT 1 FROM clipboard_entry_facets
                        WHERE entry_id = entry.id AND facet != 'text')
        """
}
