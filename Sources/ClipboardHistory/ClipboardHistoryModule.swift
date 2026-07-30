import Foundation
import GRDB

public actor ClipboardHistoryModule {
    private let database: DatabasePool
    private var monitoringEnabled = false

    init(testingDatabaseURL: URL, databaseKey: Data) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.usePassphrase(databaseKey)
        }

        let database = try DatabasePool(
            path: testingDatabaseURL.path,
            configuration: configuration
        )
        try Self.migrator.migrate(database)
        self.database = database
    }

    public func setMonitoring(
        _ command: ClipboardHistoryMonitoringCommand
    ) -> ClipboardHistoryStatus {
        monitoringEnabled = command == .start
        return status()
    }

    public func capture(
        _ request: ClipboardHistoryCaptureRequest
    ) throws -> ClipboardHistoryCaptureOutcome {
        _ = request
        throw ClipboardHistoryModuleError.operationUnavailable
    }

    public func page(
        _ query: ClipboardHistoryQuery,
        after cursor: ClipboardHistoryCursor? = nil
    ) throws -> ClipboardHistoryPage {
        _ = query
        _ = cursor
        let entryCount = try database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM clipboard_history_foundation"
            ) ?? 0
        }

        guard entryCount == 0 else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        return ClipboardHistoryPage(entries: [], nextCursor: nil)
    }

    public func apply(
        _ mutation: ClipboardHistoryMutation
    ) throws -> ClipboardHistoryMutationOutcome {
        _ = mutation
        throw ClipboardHistoryModuleError.operationUnavailable
    }

    public func materialize(
        _ request: ClipboardHistoryMaterializationRequest
    ) throws -> ClipboardHistoryMaterialization {
        _ = request
        throw ClipboardHistoryModuleError.entryNotFound
    }

    public func status() -> ClipboardHistoryStatus {
        ClipboardHistoryStatus(
            availability: .ready,
            isMonitoring: monitoringEnabled
        )
    }
}

extension ClipboardHistoryModule {
    struct FoundationRuntimeCapabilities: Equatable, Sendable {
        let sqlCipherVersion: String
        let hasFTS5: Bool
        let hasTrigramTokenizer: Bool
    }

    func foundationRuntimeCapabilities() throws -> FoundationRuntimeCapabilities {
        try database.write { database in
            let sqlCipherVersion = try database.cipherVersion
            let hasFTS5 = try Bool.fetchOne(
                database,
                sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')"
            ) ?? false

            var hasTrigramTokenizer = false
            if hasFTS5 {
                do {
                    try database.execute(
                        sql: """
                            CREATE VIRTUAL TABLE temp.foundation_trigram_probe
                            USING fts5(value, tokenize = 'trigram')
                            """
                    )
                    try database.execute(
                        sql: """
                            INSERT INTO temp.foundation_trigram_probe(value)
                            VALUES ('clipboard')
                            """
                    )
                    hasTrigramTokenizer = try Int.fetchOne(
                        database,
                        sql: """
                            SELECT COUNT(*)
                            FROM temp.foundation_trigram_probe
                            WHERE value MATCH 'board'
                            """
                    ) == 1
                    try database.execute(
                        sql: "DROP TABLE temp.foundation_trigram_probe"
                    )
                } catch {
                    hasTrigramTokenizer = false
                }
            }

            return FoundationRuntimeCapabilities(
                sqlCipherVersion: sqlCipherVersion,
                hasFTS5: hasFTS5,
                hasTrigramTokenizer: hasTrigramTokenizer
            )
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_foundation") { database in
            try database.create(table: "clipboard_history_foundation") { table in
                table.autoIncrementedPrimaryKey("id")
            }
        }
        return migrator
    }
}
