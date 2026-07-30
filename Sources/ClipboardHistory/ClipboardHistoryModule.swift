import Foundation
import GRDB

public actor ClipboardHistoryModule {
    public static var defaultStoreRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent("dev.bybee.AnyDoor")
            .appendingPathComponent("ClipboardHistory")
    }

    var database: DatabasePool?
    var monitoringEnabled = false
    let storeRoot: URL
    let keyStore: (any ClipboardHistoryMasterKeyStoring)?
    let faultInjector: ClipboardHistoryFaultInjector
    let now: @Sendable () -> Date
    var derivedKeys: ClipboardHistoryDerivedKeys?
    var availability: ClipboardHistoryStatus.Availability
    var availabilityReason: ClipboardHistoryStatus.AvailabilityReason?

    public init() {
        let root = Self.defaultStoreRoot
        let keyStore = ClipboardHistoryKeychainStore()
        let resolution = Self.resolveStore(at: root, keyStore: keyStore)
        storeRoot = root
        self.keyStore = keyStore
        faultInjector = ClipboardHistoryFaultInjector()
        now = Date.init
        database = resolution.database
        derivedKeys = resolution.keys
        availability = resolution.availability
        availabilityReason = resolution.reason
    }

    init(testingDatabaseURL: URL, databaseKey: Data) throws {
        storeRoot = testingDatabaseURL.deletingLastPathComponent()
        keyStore = nil
        faultInjector = ClipboardHistoryFaultInjector()
        now = Date.init
        try Self.prepareStoreDirectories(at: storeRoot)
        database = try Self.openDatabase(
            at: testingDatabaseURL,
            databaseKey: databaseKey
        )
        let payloadKey =
            ClipboardHistoryKeyDerivation
            .deriveV1(from: databaseKey).payloadKey
        derivedKeys = ClipboardHistoryDerivedKeys(
            version: 1,
            databaseKey: databaseKey,
            payloadKey: payloadKey
        )
        availability = .ready
        availabilityReason = nil
    }

    init(
        testingStoreRoot: URL,
        keyStore: any ClipboardHistoryMasterKeyStoring,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let resolution = Self.resolveStore(
            at: testingStoreRoot,
            keyStore: keyStore
        )
        storeRoot = testingStoreRoot
        self.keyStore = keyStore
        self.faultInjector = faultInjector
        self.now = now
        database = resolution.database
        derivedKeys = resolution.keys
        availability = resolution.availability
        availabilityReason = resolution.reason
    }

    public func setMonitoring(
        _ command: ClipboardHistoryMonitoringCommand
    ) -> ClipboardHistoryStatus {
        monitoringEnabled = command == .start && availability == .ready
        return status()
    }

    public func retry() {
        guard let keyStore else { return }
        if let database {
            try? database.close()
        }
        let resolution = Self.resolveStore(at: storeRoot, keyStore: keyStore)
        database = resolution.database
        derivedKeys = resolution.keys
        availability = resolution.availability
        availabilityReason = resolution.reason
        if availability != .ready {
            monitoringEnabled = false
        }
    }

    public func status() -> ClipboardHistoryStatus {
        ClipboardHistoryStatus(
            availability: availability,
            reason: availabilityReason,
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
        let database = try requiredDatabase()
        return try database.write { database in
            let sqlCipherVersion = try database.cipherVersion
            let hasFTS5 =
                try Bool.fetchOne(
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
                    hasTrigramTokenizer =
                        try Int.fetchOne(
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

    func requiredDatabase() throws -> DatabasePool {
        guard availability == .ready, let database else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        return database
    }

    func closeStoreForTesting() throws {
        try database?.close()
        database = nil
    }

    static func createFoundationStoreForTesting(
        at databaseURL: URL,
        databaseKey: Data
    ) throws {
        let database = try openDatabase(
            at: databaseURL,
            databaseKey: databaseKey,
            migrationTarget: "v1_foundation"
        )
        try database.close()
    }

    func damageSchemaForIntegrityTesting() throws {
        let database = try requiredDatabase()
        try database.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA writable_schema = ON")
            try database.execute(
                sql: """
                    UPDATE sqlite_schema
                    SET rootpage = 2147483647
                    WHERE name = 'clipboard_entries'
                    """
            )
            try database.execute(sql: "PRAGMA writable_schema = OFF")
        }
    }

    func damageForeignKeysForIntegrityTesting() throws {
        let database = try requiredDatabase()
        try database.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA foreign_keys = OFF")
            try database.execute(
                sql: """
                    INSERT INTO clipboard_entry_tags(entry_id, tag_id)
                    VALUES ('missing-entry', 'integrity-test')
                    """
            )
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }
}

extension ClipboardHistoryModule {
    struct StoreResolution {
        let database: DatabasePool?
        let keys: ClipboardHistoryDerivedKeys?
        let availability: ClipboardHistoryStatus.Availability
        let reason: ClipboardHistoryStatus.AvailabilityReason?
    }

    enum StoreOpenError: Error {
        case authentication
        case corrupt
        case integrity
        case io
    }

    static func databaseURL(in root: URL) -> URL {
        root.appendingPathComponent("history.sqlite")
    }

    static func resolveStore(
        at root: URL,
        keyStore: any ClipboardHistoryMasterKeyStoring
    ) -> StoreResolution {
        let databaseURL = databaseURL(in: root)
        let databaseExists = FileManager.default.fileExists(
            atPath: databaseURL.path
        )
        let storeArtifactsExist = hasStoreArtifacts(at: root)

        let masterKeyResult = keyStore.load()
        let masterKey: Data
        switch masterKeyResult {
        case .key(let key):
            masterKey = key
        case .missing where databaseExists || storeArtifactsExist:
            return unavailable(.missingKey)
        case .missing:
            switch keyStore.create() {
            case .key(let key):
                masterKey = key
            case .locked:
                return paused(.keychainLocked)
            case .accessDenied:
                return unavailable(.keyAccessDenied)
            case .missing:
                return unavailable(.keychainFailure)
            case .failure:
                return unavailable(.keychainFailure)
            }
        case .locked:
            return paused(.keychainLocked)
        case .accessDenied:
            return unavailable(.keyAccessDenied)
        case .failure:
            return unavailable(.keychainFailure)
        }

        do {
            try prepareStoreDirectories(at: root)

            let keys = ClipboardHistoryKeyDerivation.deriveV1(from: masterKey)
            let database = try openDatabase(
                at: databaseURL,
                databaseKey: keys.databaseKey
            )
            return StoreResolution(
                database: database,
                keys: keys,
                availability: .ready,
                reason: nil
            )
        } catch StoreOpenError.authentication {
            return unavailable(.databaseAuthenticationFailed)
        } catch StoreOpenError.corrupt {
            return unavailable(.databaseCorrupt)
        } catch StoreOpenError.integrity {
            return unavailable(.databaseIntegrityFailed)
        } catch {
            return unavailable(.storeIOFailure)
        }
    }

    static func unavailable(
        _ reason: ClipboardHistoryStatus.AvailabilityReason
    ) -> StoreResolution {
        StoreResolution(
            database: nil,
            keys: nil,
            availability: .unavailable,
            reason: reason
        )
    }

    static func paused(
        _ reason: ClipboardHistoryStatus.AvailabilityReason
    ) -> StoreResolution {
        StoreResolution(
            database: nil,
            keys: nil,
            availability: .paused,
            reason: reason
        )
    }

    static func openDatabase(
        at databaseURL: URL,
        databaseKey: Data,
        migrationTarget: String? = nil
    ) throws -> DatabasePool {
        let existed = FileManager.default.fileExists(atPath: databaseURL.path)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.publicStatementArguments = false
        configuration.prepareDatabase { database in
            try database.usePassphrase(databaseKey)
            try database.execute(sql: "PRAGMA cipher_memory_security = ON")
            try database.execute(sql: "PRAGMA secure_delete = ON")
        }

        do {
            let database = try DatabasePool(
                path: databaseURL.path,
                configuration: configuration
            )
            if existed {
                try validateIntegrity(of: database)
            }
            try database.writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                let mode =
                    try Int.fetchOne(
                        database,
                        sql: "PRAGMA auto_vacuum"
                    ) ?? 0
                if mode != 2 {
                    try database.execute(sql: "VACUUM")
                }
            }
            if let migrationTarget {
                try migrator.migrate(database, upTo: migrationTarget)
            } else {
                try migrator.migrate(database)
            }
            try validateIntegrity(of: database)
            return database
        } catch let error as StoreOpenError {
            throw error
        } catch let error as DatabaseError {
            switch error.resultCode {
            case .SQLITE_NOTADB:
                throw StoreOpenError.authentication
            case .SQLITE_CORRUPT:
                throw StoreOpenError.corrupt
            default:
                throw StoreOpenError.io
            }
        } catch {
            throw StoreOpenError.io
        }
    }

    static func validateIntegrity(of database: DatabasePool) throws {
        try database.read { database in
            let databaseResult = try String.fetchAll(
                database,
                sql: "PRAGMA integrity_check"
            )
            guard databaseResult == ["ok"] else {
                throw StoreOpenError.integrity
            }
            let foreignKeyFailures = try Row.fetchAll(
                database,
                sql: "PRAGMA foreign_key_check"
            )
            guard foreignKeyFailures.isEmpty else {
                throw StoreOpenError.integrity
            }
            let cipherFailures = try String.fetchAll(
                database,
                sql: "PRAGMA cipher_integrity_check"
            )
            guard cipherFailures.isEmpty || cipherFailures == ["ok"] else {
                throw StoreOpenError.integrity
            }
        }
    }

    static func hasStoreArtifacts(at root: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return false
        }
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        else {
            return true
        }
        for child in children {
            if child.lastPathComponent == "history.sqlite"
                || child.lastPathComponent == "history.sqlite-wal"
                || child.lastPathComponent == "history.sqlite-shm"
            {
                return true
            }
            if ["payloads", "staging"].contains(child.lastPathComponent),
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: child,
                    includingPropertiesForKeys: nil
                ),
                !contents.isEmpty
            {
                return true
            }
        }
        return false
    }

    static func prepareStoreDirectories(at root: URL) throws {
        for directory in [
            root,
            root.appendingPathComponent("payloads"),
            root.appendingPathComponent("staging"),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}
