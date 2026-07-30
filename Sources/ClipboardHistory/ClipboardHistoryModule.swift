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
    var monitoringRequested = false
    var monitoringConfiguration = ClipboardHistoryMonitoringConfiguration()
    var captureMonitor: ClipboardHistoryCaptureMonitor?
    let selfWriteSuppression: ClipboardHistorySelfWriteSuppression
    let monitorInstrumentation: ClipboardHistoryMonitorInstrumentation
    public nonisolated let pasteboardSelfWrites:
        ClipboardHistoryPasteboardSelfWriteFunnel
    let storeRoot: URL
    let keyStore: (any ClipboardHistoryMasterKeyStoring)?
    let faultInjector: ClipboardHistoryFaultInjector
    let payloadReclaimer = ClipboardHistoryPayloadReclaimer()
    let now: @Sendable () -> Date
    let maintenanceScheduler:
        (any ClipboardHistoryMaintenanceScheduling)?
    let storageTraversalHook: (@Sendable (URL) throws -> Void)?
    let fingerprintDigest: @Sendable (Data) -> Data
    let duplicateReuseEnabled: Bool
    var legacyDigestReadCount = 0
    var legacyMaximumDigestReadSize = 0
    let visionRecognizer: any ClipboardHistoryVisionRecognizing
    var automaticImageTextIndexingEnabled = false
    var derivedJobSchedulerTask: Task<Void, Never>?
    var derivedJobSchedulerToken: UUID?
    var activeDerivedJob: ClipboardHistoryDerivedJobKey?
    nonisolated let derivedJobBootstrap =
        ClipboardHistoryDerivedJobBootstrap()
    var searchIndexRebuildTask: Task<SearchIndexRebuildOutcome, Never>?
    var maintenanceTask: Task<Void, Never>?
    nonisolated let maintenanceBootstrap =
        ClipboardHistoryMaintenanceBootstrap()
    var isClosingStore = false
    var derivedKeys: ClipboardHistoryDerivedKeys?
    var availability: ClipboardHistoryStatus.Availability
    var availabilityReason: ClipboardHistoryStatus.AvailabilityReason?

    public init() {
        let suppression = ClipboardHistorySelfWriteSuppression()
        selfWriteSuppression = suppression
        monitorInstrumentation = ClipboardHistoryMonitorInstrumentation()
        pasteboardSelfWrites = ClipboardHistoryPasteboardSelfWriteFunnel(
            suppression: suppression
        )
        let root = Self.defaultStoreRoot
        let keyStore = ClipboardHistoryKeychainStore()
        let resolution = Self.resolveStore(
            at: root,
            keyStore: keyStore,
            maintenanceDate: Date()
        )
        storeRoot = root
        self.keyStore = keyStore
        faultInjector = ClipboardHistoryFaultInjector()
        now = Date.init
        maintenanceScheduler = SystemClipboardHistoryMaintenanceScheduler()
        storageTraversalHook = nil
        fingerprintDigest = CanonicalIdentity.sha256
        duplicateReuseEnabled = true
        visionRecognizer = ClipboardHistoryVisionRecognizer()
        database = resolution.database
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: resolution.database,
            faultInjector: faultInjector
        )
        derivedKeys = resolution.keys
        availability = resolution.availability
        availabilityReason = resolution.reason
        automaticImageTextIndexingEnabled = Self
            .storedAutomaticImageTextIndexingSetting(in: resolution.database)
        maintenanceBootstrap.install(
            Task { [weak self] in
                await self?.startMaintenanceTaskIfNeeded()
            }
        )
        derivedJobBootstrap.install(
            Task { [weak self] in
                await self?.startDerivedJobSchedulerIfNeeded()
            }
        )
    }

    init(
        testingDatabaseURL: URL,
        databaseKey: Data,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector(),
        visionRecognizer: any ClipboardHistoryVisionRecognizing =
            ClipboardHistoryVisionRecognizer()
    ) throws {
        let suppression = ClipboardHistorySelfWriteSuppression()
        selfWriteSuppression = suppression
        monitorInstrumentation = ClipboardHistoryMonitorInstrumentation()
        pasteboardSelfWrites = ClipboardHistoryPasteboardSelfWriteFunnel(
            suppression: suppression
        )
        storeRoot = testingDatabaseURL.deletingLastPathComponent()
        keyStore = nil
        self.faultInjector = faultInjector
        now = Date.init
        maintenanceScheduler = nil
        storageTraversalHook = nil
        fingerprintDigest = CanonicalIdentity.sha256
        duplicateReuseEnabled = true
        self.visionRecognizer = visionRecognizer
        try Self.prepareStoreDirectories(at: storeRoot)
        database = try Self.openDatabase(
            at: testingDatabaseURL,
            databaseKey: databaseKey
        )
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: database,
            faultInjector: faultInjector
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
        automaticImageTextIndexingEnabled = Self
            .storedAutomaticImageTextIndexingSetting(in: database)
        derivedJobBootstrap.install(
            Task { [weak self] in
                await self?.startDerivedJobSchedulerIfNeeded()
            }
        )
    }

    init(
        testingStoreRoot: URL,
        keyStore: any ClipboardHistoryMasterKeyStoring,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector(),
        now: @escaping @Sendable () -> Date = Date.init,
        maintenanceScheduler:
            (any ClipboardHistoryMaintenanceScheduling)? = nil,
        storageTraversalHook:
            (@Sendable (URL) throws -> Void)? = nil,
        fingerprintDigest: @escaping @Sendable (Data) -> Data =
            CanonicalIdentity.sha256,
        duplicateReuseEnabled: Bool = true,
        visionRecognizer: any ClipboardHistoryVisionRecognizing =
            ClipboardHistoryVisionRecognizer()
    ) {
        let suppression = ClipboardHistorySelfWriteSuppression()
        selfWriteSuppression = suppression
        monitorInstrumentation = ClipboardHistoryMonitorInstrumentation()
        pasteboardSelfWrites = ClipboardHistoryPasteboardSelfWriteFunnel(
            suppression: suppression
        )
        let resolution = Self.resolveStore(
            at: testingStoreRoot,
            keyStore: keyStore,
            maintenanceDate: now()
        )
        storeRoot = testingStoreRoot
        self.keyStore = keyStore
        self.faultInjector = faultInjector
        self.now = now
        self.maintenanceScheduler = maintenanceScheduler
        self.storageTraversalHook = storageTraversalHook
        self.fingerprintDigest = fingerprintDigest
        self.duplicateReuseEnabled = duplicateReuseEnabled
        self.visionRecognizer = visionRecognizer
        database = resolution.database
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: resolution.database,
            faultInjector: faultInjector
        )
        derivedKeys = resolution.keys
        availability = resolution.availability
        availabilityReason = resolution.reason
        automaticImageTextIndexingEnabled = Self
            .storedAutomaticImageTextIndexingSetting(in: resolution.database)
        maintenanceBootstrap.install(
            Task { [weak self] in
                await self?.startMaintenanceTaskIfNeeded()
            }
        )
        derivedJobBootstrap.install(
            Task { [weak self] in
                await self?.startDerivedJobSchedulerIfNeeded()
            }
        )
    }

    public func setMonitoring(
        _ command: ClipboardHistoryMonitoringCommand,
        configuration: ClipboardHistoryMonitoringConfiguration? = nil
    ) async -> ClipboardHistoryStatus {
        if let configuration {
            monitoringConfiguration = configuration
        }
        let monitor: ClipboardHistoryCaptureMonitor
        if let captureMonitor {
            monitor = captureMonitor
            await monitor.updateConfiguration(monitoringConfiguration)
        } else {
            monitor = await ClipboardHistoryCaptureMonitor(
                module: self,
                suppression: selfWriteSuppression,
                instrumentation: monitorInstrumentation,
                configuration: monitoringConfiguration
            )
            captureMonitor = monitor
        }

        switch command {
        case .start:
            monitoringRequested = true
            monitoringEnabled = availability == .ready
            await monitor.setEnabled(
                monitoringEnabled,
                configuration: monitoringConfiguration
            )
        case .stop:
            monitoringRequested = false
            monitoringEnabled = false
            await monitor.setEnabled(false)
        case .migrationStarted:
            monitoringEnabled = false
            await monitor.handleLifecycle(.migrationStarted)
        case .migrationCompleted:
            monitoringEnabled = monitoringRequested && availability == .ready
            await monitor.handleLifecycle(.migrationCompleted)
            await monitor.setEnabled(
                monitoringEnabled,
                configuration: monitoringConfiguration
            )
        }
        return status()
    }

    public func retry() async {
        guard let keyStore else { return }
        await stopMaintenanceTask()
        await stopDerivedJobScheduler()
        _ = await searchIndexRebuildTask?.value
        searchIndexRebuildTask = nil
        if let database {
            try? database.close()
        }
        let resolution = Self.resolveStore(
            at: storeRoot,
            keyStore: keyStore,
            maintenanceDate: now()
        )
        database = resolution.database
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: resolution.database,
            faultInjector: faultInjector
        )
        derivedKeys = resolution.keys
        availability = resolution.availability
        availabilityReason = resolution.reason
        automaticImageTextIndexingEnabled = Self
            .storedAutomaticImageTextIndexingSetting(in: resolution.database)
        if availability != .ready {
            monitoringEnabled = false
            await captureMonitor?.setEnabled(false)
        } else if monitoringRequested {
            monitoringEnabled = true
            await captureMonitor?.setEnabled(true)
        }
        startMaintenanceTaskIfNeeded()
        startDerivedJobSchedulerIfNeeded()
    }

    public func status() -> ClipboardHistoryStatus {
        ClipboardHistoryStatus(
            availability: availability,
            reason: availabilityReason,
            isMonitoring: monitoringEnabled,
            searchIndex: currentSearchIndexStatus()
        )
    }

    public func retrySearchIndex() throws
        -> ClipboardHistorySearchIndexStatus
    {
        guard !isClosingStore else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let database = try requiredDatabase()
        let status = try database.read {
            try Self.searchIndexStatus(in: $0)
        }
        guard case .failed = status else {
            return status
        }
        searchIndexRebuildTask = try Self.retrySearchIndexes(
            in: database,
            faultInjector: faultInjector
        )
        return .indexing
    }

    private func currentSearchIndexStatus()
        -> ClipboardHistorySearchIndexStatus?
    {
        guard availability == .ready, let database else {
            return nil
        }
        do {
            return try database.read {
                try Self.searchIndexStatus(in: $0)
            }
        } catch {
            return .failed(.stateUnavailable)
        }
    }

    public func monitorMetrics() -> ClipboardHistoryMonitorMetrics {
        monitorInstrumentation.snapshot()
    }

    public func advanceMonitoringBaseline() async {
        await captureMonitor?.establishBaseline()
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

    func closeStoreForTesting() async throws {
        guard !isClosingStore else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        isClosingStore = true
        await stopMaintenanceTask()
        await stopDerivedJobScheduler()
        let rebuildTask = searchIndexRebuildTask
        if let rebuildTask {
            _ = await rebuildTask.value
        }
        searchIndexRebuildTask = nil
        do {
            try database?.close()
            database = nil
            isClosingStore = false
        } catch {
            isClosingStore = false
            throw error
        }
    }

    func awaitSearchIndexRebuildForTesting() async {
        _ = await searchIndexRebuildTask?.value
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

    enum StoreOpenError: Error, Equatable {
        case authentication
        case corrupt
        case integrity
        case unsupportedSearchIndex
        case io
    }

    static func databaseURL(in root: URL) -> URL {
        root.appendingPathComponent("history.sqlite")
    }

    static func resolveStore(
        at root: URL,
        keyStore: any ClipboardHistoryMasterKeyStoring,
        maintenanceDate: Date
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
            case .interactionRequired:
                return unavailable(.keyAccessDenied)
            case .accessDenied:
                return unavailable(.keyAccessDenied)
            case .missing:
                return unavailable(.keychainFailure)
            case .failure:
                return unavailable(.keychainFailure)
            }
        case .locked:
            return paused(.keychainLocked)
        case .interactionRequired:
            return unavailable(.keyAccessDenied)
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
            try database.write { database in
                _ = try ensureMaintenanceDeadline(
                    in: database,
                    at: maintenanceDate
                )
            }
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
        } catch StoreOpenError.unsupportedSearchIndex {
            return unavailable(.searchIndexUnavailable)
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
            try validateSearchRuntimeCapabilities(of: database)
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
                try prepareSearchIndexState(in: database)
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
