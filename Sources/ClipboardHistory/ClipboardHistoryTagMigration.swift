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

struct ClipboardHistoryLegacyTagImportResult: Sendable {
    let didMutate: Bool
    let recoveryFormat: ClipboardHistoryLegacyTagPreference.Format?
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
        guard legacyTagImportStoreTransitions == 0 else { throw ClipboardHistoryModuleError.operationUnavailable }
        try Task.checkCancellation()
        // A completed import is a read, including when invalid input was retained.
        // Read the committed WAL snapshot before joining the index rebuild's writer.
        // The worker below rechecks the marker atomically for a first import.
        let completed = try Self.completedLegacyTagImport(in: requiredDatabase())
        if let completed { return completed.recoveryFormat }
        let pool = try await writableDatabase()
        guard legacyTagImportStoreTransitions == 0 else { throw ClipboardHistoryModuleError.operationUnavailable }
        let epoch = storeEpoch
        let faults = faultInjector
        let worker = Task.detached(priority: .utility) {
            try Self.importLegacyTags(source, in: pool, faultInjector: faults)
        }
        legacyTagImportTask = worker
        defer { if legacyTagImportTask == worker { legacyTagImportTask = nil } }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard epoch == storeEpoch, database === pool else { throw ClipboardHistoryModuleError.storeUnavailable }
        if result.didMutate { publishMutation() }
        return result.recoveryFormat
    }

    func stopLegacyTagImport() async {
        guard let worker = legacyTagImportTask else { return }
        worker.cancel()
        _ = try? await worker.value
        if legacyTagImportTask == worker { legacyTagImportTask = nil }
    }

    private static func importLegacyTags(_ source: ClipboardHistoryLegacyTagPreference, in pool: DatabasePool,
        faultInjector: ClipboardHistoryFaultInjector) throws -> ClipboardHistoryLegacyTagImportResult {
        try Task.checkCancellation()
        return try pool.write { database in
            guard try !legacyTagDefinitionsImported(in: database) else {
                return .init(didMutate: false, recoveryFormat: try legacyTagRecoveryFormat(in: database))
            }
            // Validate the complete input before writing any definitions. Only
            // input errors take the preservation path; SQL failures still throw.
            if let tags = Self.validLegacyTags(from: source) {
                for tag in tags {
                    try Task.checkCancellation()
                    try database.execute(sql: """
                        INSERT INTO clipboard_tag_definitions(id, display_name, display_order)
                        VALUES (?, ?, COALESCE((SELECT MAX(display_order) + 1 FROM clipboard_tag_definitions), 0))
                        ON CONFLICT(id) DO NOTHING
                        """, arguments: [tag.id, tag.name.trimmingCharacters(in: .whitespacesAndNewlines)])
                }
                try database.execute(sql: """
                    UPDATE clipboard_retention_state SET is_protected = (
                        SELECT entry.is_favorite = 1 OR EXISTS (
                            SELECT 1 FROM clipboard_entry_tags AS assignment
                            JOIN clipboard_tag_definitions AS definition ON definition.id = assignment.tag_id
                            WHERE assignment.entry_id = entry.id)
                        FROM clipboard_entries AS entry WHERE entry.id = clipboard_retention_state.entry_id)
                    WHERE entry_id IN (SELECT DISTINCT entry_id FROM clipboard_entry_tags)
                    """)
            } else {
                try database.execute(sql: """
                    INSERT INTO clipboard_legacy_tag_recovery(id, format, original_value) VALUES (1, ?, ?)
                    """, arguments: [source.format.rawValue, source.data])
            }
            try Self.markLegacyTagDefinitionsImported(in: database)
            try Self.bumpHistoryRevision(in: database)
            try Self.bumpSearchIndexGeneration(in: database)
            try faultInjector.check(.databaseTransaction)
            try Task.checkCancellation()
            return .init(didMutate: true, recoveryFormat: try legacyTagRecoveryFormat(in: database))
        }
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

    private static func legacyTagDefinitionsImported(in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT integer_value FROM clipboard_maintenance_metadata WHERE key = 'legacyTagDefaultsImported'
            """) ?? false
    }

    private static func completedLegacyTagImport(in pool: DatabasePool) throws -> ClipboardHistoryLegacyTagImportResult? {
        try pool.read { database in
            guard try legacyTagDefinitionsImported(in: database) else { return nil }
            return .init(didMutate: false, recoveryFormat: try legacyTagRecoveryFormat(in: database))
        }
    }
}
