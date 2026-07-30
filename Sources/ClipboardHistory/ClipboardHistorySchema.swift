import Foundation
import GRDB

extension ClipboardHistoryModule {
    struct StorageDiagnostics: Equatable, Sendable {
        let appliedMigrations: [String]
        let tables: [String]
        let journalMode: String
        let foreignKeysEnabled: Bool
        let autoVacuumMode: Int
        let secureDeleteEnabled: Bool
        let databaseIntegrityOK: Bool
        let foreignKeyIntegrityOK: Bool
        let cipherIntegrityOK: Bool
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_foundation") { database in
            try database.create(table: "clipboard_history_foundation") { table in
                table.autoIncrementedPrimaryKey("id")
            }
        }
        migrator.registerMigration("v2_encrypted_store") { database in
            try createEncryptedStoreSchema(in: database)
        }
        migrator.registerMigration("v3_file_reference_identity") { database in
            try database.alter(table: "clipboard_file_members") { table in
                table.add(column: "identity_data", .blob)
            }
        }
        migrator.registerMigration("v4_capture_source_provenance") { database in
            try database.alter(table: "clipboard_entries") { table in
                table.add(
                    column: "source_provenance",
                    .text
                ).notNull().defaults(to: "unknown")
            }
        }
        migrator.registerMigration("v5_indexed_search") { database in
            try createSearchIndexSchema(in: database)
        }
        migrator.registerMigration("v6_retention_and_mutations") { database in
            try createRetentionMutationSchema(in: database)
        }
        migrator.registerMigration("v7_derived_indexing") { database in
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(
                        key, integer_value
                    ) VALUES ('automaticImageTextIndexingEnabled', 0)
                    ON CONFLICT(key) DO NOTHING
                    """
            )
        }
        return migrator
    }

    func storageDiagnostics() throws -> StorageDiagnostics {
        let database = try requiredDatabase()
        return try database.read { database in
            let migrations = try String.fetchAll(
                database,
                sql: """
                    SELECT identifier
                    FROM grdb_migrations
                    ORDER BY rowid
                    """
            )
            let tables = try String.fetchAll(
                database,
                sql: """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table'
                      AND name LIKE 'clipboard_%'
                    ORDER BY name
                    """
            )
            let journalMode =
                try String.fetchOne(
                    database,
                    sql: "PRAGMA journal_mode"
                ) ?? ""
            let foreignKeysEnabled =
                try Int.fetchOne(
                    database,
                    sql: "PRAGMA foreign_keys"
                ) == 1
            let autoVacuumMode =
                try Int.fetchOne(
                    database,
                    sql: "PRAGMA auto_vacuum"
                ) ?? 0
            let secureDeleteEnabled =
                try Int.fetchOne(
                    database,
                    sql: "PRAGMA secure_delete"
                ) == 1
            let databaseIntegrity = try String.fetchAll(
                database,
                sql: "PRAGMA integrity_check"
            )
            let foreignKeyFailures = try Row.fetchAll(
                database,
                sql: "PRAGMA foreign_key_check"
            )
            let cipherFailures = try String.fetchAll(
                database,
                sql: "PRAGMA cipher_integrity_check"
            )

            return StorageDiagnostics(
                appliedMigrations: migrations,
                tables: tables,
                journalMode: journalMode,
                foreignKeysEnabled: foreignKeysEnabled,
                autoVacuumMode: autoVacuumMode,
                secureDeleteEnabled: secureDeleteEnabled,
                databaseIntegrityOK: databaseIntegrity == ["ok"],
                foreignKeyIntegrityOK: foreignKeyFailures.isEmpty,
                cipherIntegrityOK: cipherFailures.isEmpty || cipherFailures == ["ok"]
            )
        }
    }

    private static func createRetentionMutationSchema(
        in database: Database
    ) throws {
        try database.create(table: "clipboard_tag_definitions") { table in
            table.primaryKey("id", .text)
        }
        try database.execute(
            sql: """
                CREATE INDEX clipboard_retention_expiry
                ON clipboard_retention_state(
                    is_protected,
                    retention_started_at,
                    entry_id
                )
                """
        )
        for (key, textValue) in [
            ("retentionPeriod", ClipboardHistoryRetentionPeriod.default.rawValue)
        ] {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(key, text_value)
                    VALUES (?, ?)
                    ON CONFLICT(key) DO NOTHING
                    """,
                arguments: [key, textValue]
            )
        }
        try database.execute(
            sql: """
                INSERT INTO clipboard_maintenance_metadata(key, integer_value)
                VALUES ('historyRevision', 0)
                ON CONFLICT(key) DO NOTHING
                """
        )
    }
}

extension ClipboardHistoryModule {
    fileprivate static func createEncryptedStoreSchema(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE TABLE clipboard_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    captured_at DOUBLE NOT NULL,
                    last_captured_at DOUBLE NOT NULL,
                    source_bundle_id TEXT,
                    source_display_name TEXT,
                    preview_text TEXT,
                    is_favorite INTEGER NOT NULL DEFAULT 0
                        CHECK (is_favorite IN (0, 1)),
                    edited_at DOUBLE,
                    thumbnail_payload_id TEXT
                        REFERENCES clipboard_payloads(id) ON DELETE RESTRICT
                )
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_items (
                    entry_id TEXT NOT NULL
                        REFERENCES clipboard_entries(id) ON DELETE CASCADE,
                    item_index INTEGER NOT NULL CHECK (item_index >= 0),
                    PRIMARY KEY (entry_id, item_index)
                ) WITHOUT ROWID
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_payloads (
                    id TEXT PRIMARY KEY NOT NULL,
                    relative_path TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL
                        CHECK (kind IN ('bitmap', 'thumbnail', 'legacyOwnedFile')),
                    crypto_version INTEGER NOT NULL CHECK (crypto_version > 0),
                    plaintext_byte_count INTEGER NOT NULL
                        CHECK (plaintext_byte_count >= 0),
                    created_at DOUBLE NOT NULL
                )
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_representations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entry_id TEXT NOT NULL,
                    item_index INTEGER NOT NULL,
                    representation_index INTEGER NOT NULL
                        CHECK (representation_index >= 0),
                    kind TEXT NOT NULL,
                    type_identifier TEXT NOT NULL,
                    text_value TEXT,
                    data_value BLOB,
                    payload_id TEXT
                        REFERENCES clipboard_payloads(id) ON DELETE RESTRICT,
                    FOREIGN KEY (entry_id, item_index)
                        REFERENCES clipboard_items(entry_id, item_index)
                        ON DELETE CASCADE,
                    UNIQUE (entry_id, item_index, representation_index),
                    CHECK (
                        (text_value IS NOT NULL) +
                        (data_value IS NOT NULL) +
                        (payload_id IS NOT NULL) = 1
                    )
                )
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_entry_facets (
                    entry_id TEXT NOT NULL
                        REFERENCES clipboard_entries(id) ON DELETE CASCADE,
                    facet TEXT NOT NULL,
                    PRIMARY KEY (entry_id, facet)
                ) WITHOUT ROWID
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_file_members (
                    entry_id TEXT NOT NULL,
                    item_index INTEGER NOT NULL,
                    member_index INTEGER NOT NULL CHECK (member_index >= 0),
                    captured_path TEXT NOT NULL,
                    current_path TEXT,
                    display_name TEXT NOT NULL,
                    bookmark_data BLOB,
                    resource_type TEXT,
                    availability TEXT NOT NULL,
                    payload_id TEXT
                        REFERENCES clipboard_payloads(id) ON DELETE RESTRICT,
                    FOREIGN KEY (entry_id, item_index)
                        REFERENCES clipboard_items(entry_id, item_index)
                        ON DELETE CASCADE,
                    PRIMARY KEY (entry_id, item_index, member_index)
                ) WITHOUT ROWID
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_search_fields (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entry_id TEXT NOT NULL
                        REFERENCES clipboard_entries(id) ON DELETE CASCADE,
                    field_kind TEXT NOT NULL,
                    field_index INTEGER NOT NULL CHECK (field_index >= 0),
                    value TEXT NOT NULL,
                    normalized_value TEXT NOT NULL,
                    ranking_group INTEGER NOT NULL,
                    UNIQUE (entry_id, field_kind, field_index)
                )
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_entry_tags (
                    entry_id TEXT NOT NULL
                        REFERENCES clipboard_entries(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL,
                    PRIMARY KEY (entry_id, tag_id)
                ) WITHOUT ROWID
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_duplicate_candidates (
                    fingerprint BLOB NOT NULL,
                    entry_id TEXT NOT NULL
                        REFERENCES clipboard_entries(id) ON DELETE CASCADE,
                    canonical_byte_count INTEGER NOT NULL
                        CHECK (canonical_byte_count >= 0),
                    created_at DOUBLE NOT NULL,
                    PRIMARY KEY (fingerprint, entry_id)
                ) WITHOUT ROWID
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_derived_jobs (
                    entry_id TEXT NOT NULL
                        REFERENCES clipboard_entries(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (kind IN ('ocr', 'qr')),
                    state TEXT NOT NULL
                        CHECK (state IN ('pending', 'running', 'succeeded', 'failed')),
                    attempt_count INTEGER NOT NULL DEFAULT 0
                        CHECK (attempt_count BETWEEN 0 AND 3),
                    eligible_generation INTEGER NOT NULL,
                    next_attempt_at DOUBLE,
                    PRIMARY KEY (entry_id, kind)
                ) WITHOUT ROWID
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_retention_state (
                    entry_id TEXT PRIMARY KEY NOT NULL
                        REFERENCES clipboard_entries(id) ON DELETE CASCADE,
                    retention_started_at DOUBLE NOT NULL,
                    is_protected INTEGER NOT NULL DEFAULT 0
                        CHECK (is_protected IN (0, 1))
                ) WITHOUT ROWID
                """
        )
        try database.execute(
            sql: """
                CREATE TABLE clipboard_maintenance_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    integer_value INTEGER,
                    real_value DOUBLE,
                    text_value TEXT,
                    data_value BLOB,
                    CHECK (
                        (integer_value IS NOT NULL) +
                        (real_value IS NOT NULL) +
                        (text_value IS NOT NULL) +
                        (data_value IS NOT NULL) <= 1
                    )
                ) WITHOUT ROWID
                """
        )

        try database.execute(
            sql: """
                CREATE INDEX clipboard_entries_recency
                ON clipboard_entries(last_captured_at DESC, id DESC)
                """
        )
        try database.execute(
            sql: """
                CREATE INDEX clipboard_representations_payload
                ON clipboard_representations(payload_id)
                WHERE payload_id IS NOT NULL
                """
        )
        try database.execute(
            sql: """
                CREATE INDEX clipboard_file_members_payload
                ON clipboard_file_members(payload_id)
                WHERE payload_id IS NOT NULL
                """
        )
        try database.execute(
            sql: """
                CREATE INDEX clipboard_search_fields_entry
                ON clipboard_search_fields(entry_id)
                """
        )
        try database.execute(
            sql: """
                CREATE INDEX clipboard_derived_jobs_state
                ON clipboard_derived_jobs(state, next_attempt_at)
                """
        )
        try database.execute(
            sql: """
                INSERT INTO clipboard_maintenance_metadata(key, integer_value)
                VALUES ('schemaGeneration', 2)
                """
        )
    }
}
