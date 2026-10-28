import Foundation
import GRDB

private struct LegacyTagDefaultsRecord: Decodable {
    let id: String
    let name: String
}

extension ClipboardHistoryModule {
    /// One-time import of the retired preferences mirror. Current encrypted
    /// identities and memberships are authoritative; stale mirrors cannot
    /// rename, remove, or repeatedly resurrect them after a restart.
    public func importLegacyTagDefinitions(_ data: Data) async throws {
        _ = try await writableDatabase()
        let changed = try syncWrite { database in
            let imported = try Bool.fetchOne(database, sql: """
                SELECT integer_value FROM clipboard_maintenance_metadata WHERE key = 'legacyTagDefaultsImported'
                """) ?? false
            guard !imported else { return false }
            let tags: [LegacyTagDefaultsRecord]
            do { tags = try JSONDecoder().decode([LegacyTagDefaultsRecord].self, from: data) }
            catch { throw ClipboardHistoryModuleError.invalidTagName }
            guard Set(tags.map(\.id)).count == tags.count, tags.allSatisfy({ !$0.id.isEmpty }) else {
                throw ClipboardHistoryModuleError.invalidTagIDs(Set(tags.map(\.id)))
            }
            for tag in tags {
                let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ClipboardHistoryModuleError.invalidTagName }
                try database.execute(sql: """
                    INSERT INTO clipboard_tag_definitions(id, display_name, display_order)
                    VALUES (?, ?, COALESCE((SELECT MAX(display_order) + 1 FROM clipboard_tag_definitions), 0))
                    ON CONFLICT(id) DO NOTHING
                    """, arguments: [tag.id, name])
            }
            for id in try String.fetchAll(database, sql: "SELECT DISTINCT entry_id FROM clipboard_entry_tags") {
                _ = try recomputeProtection(for: id, in: database)
            }
            try Self.markLegacyTagDefinitionsImported(in: database)
            try Self.bumpHistoryRevision(in: database)
            try Self.bumpSearchIndexGeneration(in: database)
            try faultInjector.check(.databaseTransaction)
            return true
        }
        if changed { publishMutation() }
    }

    static func markLegacyTagDefinitionsImported(in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_maintenance_metadata(key, integer_value) VALUES ('legacyTagDefaultsImported', 1)
            ON CONFLICT(key) DO UPDATE SET integer_value = 1
            """)
    }
}
