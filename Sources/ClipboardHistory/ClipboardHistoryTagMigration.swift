import Foundation
import GRDB

private struct LegacyTagDefaultsRecord: Decodable {
    let id: String
    let name: String
}

/// The original retired preference, retained without interpreting invalid data.
/// Property-list data preserves the type of a non-string preference value.
public struct ClipboardHistoryLegacyTagPreference: Equatable, Sendable {
    public enum Format: String, Sendable {
        case json
        case propertyList
    }

    public let format: Format
    public let data: Data

    public init(format: Format, data: Data) {
        self.format = format
        self.data = data
    }
}

extension ClipboardHistoryModule {
    /// One-time import of the retired preferences mirror. Current encrypted
    /// identities and memberships are authoritative; stale mirrors cannot
    /// rename, remove, or repeatedly resurrect them after a restart.
    /// Invalid input is preserved in the encrypted store for explicit recovery.
    /// The returned format means that recovery remains available, even on restart.
    public func importLegacyTagDefinitions(
        _ source: ClipboardHistoryLegacyTagPreference
    ) async throws -> ClipboardHistoryLegacyTagPreference.Format? {
        _ = try await writableDatabase()
        let result = try syncWrite { database in
            let imported = try Bool.fetchOne(database, sql: """
                SELECT integer_value FROM clipboard_maintenance_metadata WHERE key = 'legacyTagDefaultsImported'
                """) ?? false
            guard !imported else {
                return (false, try Self.legacyTagRecoveryFormat(in: database))
            }
            // Validate the complete input before writing any definitions. Only
            // input errors take the preservation path; SQL failures still throw.
            if let tags = Self.validLegacyTags(from: source) {
                for tag in tags {
                    try database.execute(sql: """
                        INSERT INTO clipboard_tag_definitions(id, display_name, display_order)
                        VALUES (?, ?, COALESCE((SELECT MAX(display_order) + 1 FROM clipboard_tag_definitions), 0))
                        ON CONFLICT(id) DO NOTHING
                        """, arguments: [tag.id, tag.name.trimmingCharacters(in: .whitespacesAndNewlines)])
                }
                for id in try String.fetchAll(database, sql: "SELECT DISTINCT entry_id FROM clipboard_entry_tags") {
                    _ = try recomputeProtection(for: id, in: database)
                }
            } else {
                try database.execute(sql: """
                    INSERT INTO clipboard_legacy_tag_recovery(id, format, original_value) VALUES (1, ?, ?)
                    """, arguments: [source.format.rawValue, source.data])
            }
            try Self.markLegacyTagDefinitionsImported(in: database)
            try Self.bumpHistoryRevision(in: database)
            try Self.bumpSearchIndexGeneration(in: database)
            try faultInjector.check(.databaseTransaction)
            return (true, try Self.legacyTagRecoveryFormat(in: database))
        }
        if result.0 { publishMutation() }
        return result.1
    }

    /// Reads retained input only for an explicit recovery/export action. Normal
    /// startup exposes its format, without loading the original into Host state.
    public func legacyTagRecovery() throws -> ClipboardHistoryLegacyTagPreference? {
        let database = try requiredDatabase()
        return try database.read { database in
            guard let format = try Self.legacyTagRecoveryFormat(in: database) else { return nil }
            guard let data = try Data.fetchOne(database, sql: """
                SELECT original_value FROM clipboard_legacy_tag_recovery WHERE id = 1
                """) else { throw ClipboardHistoryModuleError.storageFailure }
            return ClipboardHistoryLegacyTagPreference(format: format, data: data)
        }
    }

    static func createLegacyTagRecoverySchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_legacy_tag_recovery (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                format TEXT NOT NULL,
                original_value BLOB NOT NULL
            )
            """)
    }

    private static func validLegacyTags(
        from source: ClipboardHistoryLegacyTagPreference
    ) -> [LegacyTagDefaultsRecord]? {
        guard source.format == .json,
              let tags = try? JSONDecoder().decode([LegacyTagDefaultsRecord].self, from: source.data),
              Set(tags.map(\.id)).count == tags.count,
              tags.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
        return tags
    }

    private static func legacyTagRecoveryFormat(
        in database: Database
    ) throws -> ClipboardHistoryLegacyTagPreference.Format? {
        guard let value = try String.fetchOne(database, sql: """
            SELECT format FROM clipboard_legacy_tag_recovery WHERE id = 1
            """) else { return nil }
        guard let format = ClipboardHistoryLegacyTagPreference.Format(rawValue: value) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        return format
    }

    static func markLegacyTagDefinitionsImported(in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_maintenance_metadata(key, integer_value) VALUES ('legacyTagDefaultsImported', 1)
            ON CONFLICT(key) DO UPDATE SET integer_value = 1
            """)
    }
}
