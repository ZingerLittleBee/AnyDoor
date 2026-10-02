import Foundation
import GRDB

public actor ClipboardHistoryModule {
    /// The encrypted store's own folder, beside `legacyPayloadDirectory`.
    /// A store still found in the legacy folder is moved here on launch.
    public static var defaultStoreRoot: URL {
        applicationDataDirectory.appendingPathComponent("ClipboardHistoryV2")
    }

    /// Where pre-v2 releases keep clipboard payloads, and where the legacy
    /// migration reads them from. It was also the store root for 4.2.0
    /// through 4.2.5, which is how running a pre-v2 release could delete the
    /// store: those releases remove files they do not recognize from this
    /// folder. No v2 file may be created here.
    public static var legacyPayloadDirectory: URL {
        legacyPayloadDirectory(in: applicationDataDirectory)
    }

    /// `legacyPayloadDirectory` inside `applicationDataDirectory` (the
    /// app's `Application Support/dev.bybee.AnyDoor` folder in production),
    /// so the app's migration wiring can run against a temporary folder.
    public static func legacyPayloadDirectory(
        in applicationDataDirectory: URL
    ) -> URL {
        applicationDataDirectory.appendingPathComponent("ClipboardHistory")
    }

    private static var applicationDataDirectory: URL {
        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return applicationSupport.appendingPathComponent("dev.bybee.AnyDoor")
    }

    var database: DatabasePool?
    var monitoringEnabled = false
    var monitoringRequested = false
    var monitoringConfiguration = ClipboardHistoryMonitoringConfiguration()
    var captureMonitor: ClipboardHistoryCaptureMonitor?
    var isFinalizingClear = false
    /// Advances when a clear applies, so a passive capture that waited for its
    /// write turn can tell that the history it read the pasteboard for has
    /// been cleared since. `isFinalizingClear` already turns away a capture
    /// served while the clear is in flight; this also covers one that actor
    /// scheduling only resumes once the clear has finished.
    var clearEpoch = 0
    /// Advances when a reset replaces the store, so a writer still waiting
    /// for its write turn cannot land in the new store (see
    /// `waitForWriteTurn()`).
    var storeEpoch = 0
    let selfWriteSuppression: ClipboardHistorySelfWriteSuppression
    let monitorInstrumentation: ClipboardHistoryMonitorInstrumentation
    let captureNoticeHandler: ClipboardHistoryCaptureNoticeHandler?
    let notificationCenter: NotificationCenter
    public nonisolated let pasteboardSelfWrites:
        ClipboardHistoryPasteboardSelfWriteFunnel
    let storeRoot: URL
    /// Moves a store out of the pre-v2 folder before every open. Nil only
    /// for test modules that do not model the legacy folder.
    let relocation: ClipboardHistoryStoreRelocation?
    let keyStore: (any ClipboardHistoryMasterKeyStoring)?
    let faultInjector: ClipboardHistoryFaultInjector
    /// The app build failed search index rebuilds are counted against
    /// (`CFBundleVersion` in production): a different build gets the whole
    /// retry budget again (see `searchIndexRebuildFailureLimit`).
    let appBuild: String
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
    private var nextWriteTurn = 0
    private var currentWriteTurn = 0
    private var writeTurnWaiters: [CheckedContinuation<Void, Never>] = []
    var maintenanceTask: Task<Void, Never>?
    nonisolated let maintenanceBootstrap =
        ClipboardHistoryMaintenanceBootstrap()
    var isClosingStore = false
    var derivedKeys: ClipboardHistoryDerivedKeys?
    var availability: ClipboardHistoryStatus.Availability
    var availabilityReason: ClipboardHistoryStatus.AvailabilityReason?

    /// The `appBuild` of a build without a `CFBundleVersion` (`swift run`),
    /// fixed so that relaunching one never resets the retry budget.
    static let unversionedAppBuild = "unversioned"

    /// `captureNotices` receives passive capture notices. It is fixed at
    /// construction so no observed change can precede it.
    public init(
        captureNotices: ClipboardHistoryCaptureNoticeHandler? = nil
    ) {
        let suppression = ClipboardHistorySelfWriteSuppression()
        selfWriteSuppression = suppression
        monitorInstrumentation = ClipboardHistoryMonitorInstrumentation()
        captureNoticeHandler = captureNotices
        notificationCenter = .default
        pasteboardSelfWrites = ClipboardHistoryPasteboardSelfWriteFunnel(
            suppression: suppression
        )
        let root = Self.defaultStoreRoot
        let acceptanceKeychainPath = ProcessInfo.processInfo.environment[
            "ANYDOOR_CLIPBOARD_HISTORY_ACCEPTANCE_KEYCHAIN_PATH"
        ]
        let keyStore = if let acceptanceKeychainPath,
            !acceptanceKeychainPath.isEmpty
        {
            ClipboardHistoryKeychainStore(
                testingKeychainPath: acceptanceKeychainPath,
                allowsInteraction: false
            )
        } else {
            ClipboardHistoryKeychainStore()
        }
        let faultInjector = ClipboardHistoryFaultInjector()
        let appBuild =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? Self.unversionedAppBuild
        let relocation = ClipboardHistoryStoreRelocation(
            legacyRoot: Self.legacyPayloadDirectory,
            storeRoot: root,
            faultInjector: faultInjector
        )
        let resolution = Self.relocateAndResolveStore(
            relocation: relocation,
            at: root,
            keyStore: keyStore,
            maintenanceDate: Date()
        )
        storeRoot = root
        self.relocation = relocation
        self.keyStore = keyStore
        self.faultInjector = faultInjector
        self.appBuild = appBuild
        now = Date.init
        maintenanceScheduler = SystemClipboardHistoryMaintenanceScheduler()
        storageTraversalHook = nil
        fingerprintDigest = CanonicalIdentity.sha256
        duplicateReuseEnabled = true
        visionRecognizer = ClipboardHistoryVisionRecognizer()
        database = resolution.database
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: resolution.database,
            faultInjector: faultInjector,
            appBuild: appBuild
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
            ClipboardHistoryVisionRecognizer(),
        notificationCenter: NotificationCenter = .default,
        appBuild: String = unversionedAppBuild
    ) throws {
        let suppression = ClipboardHistorySelfWriteSuppression()
        selfWriteSuppression = suppression
        monitorInstrumentation = ClipboardHistoryMonitorInstrumentation()
        captureNoticeHandler = nil
        self.notificationCenter = notificationCenter
        pasteboardSelfWrites = ClipboardHistoryPasteboardSelfWriteFunnel(
            suppression: suppression
        )
        storeRoot = testingDatabaseURL.deletingLastPathComponent()
        relocation = nil
        keyStore = nil
        self.faultInjector = faultInjector
        self.appBuild = appBuild
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
            faultInjector: faultInjector,
            appBuild: appBuild
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

    /// `legacyStoreRoot` models the pre-v2 folder beside `testingStoreRoot`;
    /// when given, every open first moves a store out of it, as in
    /// production.
    init(
        testingStoreRoot: URL,
        legacyStoreRoot: URL? = nil,
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
            ClipboardHistoryVisionRecognizer(),
        notificationCenter: NotificationCenter = .default,
        captureNotices: ClipboardHistoryCaptureNoticeHandler? = nil,
        appBuild: String = unversionedAppBuild
    ) {
        let suppression = ClipboardHistorySelfWriteSuppression()
        selfWriteSuppression = suppression
        monitorInstrumentation = ClipboardHistoryMonitorInstrumentation()
        captureNoticeHandler = captureNotices
        self.notificationCenter = notificationCenter
        pasteboardSelfWrites = ClipboardHistoryPasteboardSelfWriteFunnel(
            suppression: suppression
        )
        let relocation = legacyStoreRoot.map {
            ClipboardHistoryStoreRelocation(
                legacyRoot: $0,
                storeRoot: testingStoreRoot,
                faultInjector: faultInjector
            )
        }
        let resolution = Self.relocateAndResolveStore(
            relocation: relocation,
            at: testingStoreRoot,
            keyStore: keyStore,
            maintenanceDate: now()
        )
        storeRoot = testingStoreRoot
        self.relocation = relocation
        self.keyStore = keyStore
        self.faultInjector = faultInjector
        self.appBuild = appBuild
        self.now = now
        self.maintenanceScheduler = maintenanceScheduler
        self.storageTraversalHook = storageTraversalHook
        self.fingerprintDigest = fingerprintDigest
        self.duplicateReuseEnabled = duplicateReuseEnabled
        self.visionRecognizer = visionRecognizer
        database = resolution.database
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: resolution.database,
            faultInjector: faultInjector,
            appBuild: appBuild
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
                configuration: monitoringConfiguration,
                isKeychainUnlocked: {
                    ClipboardHistoryKeychainLock.isLoginKeychainUnlocked()
                }
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
        let resolution = Self.relocateAndResolveStore(
            relocation: relocation,
            at: storeRoot,
            keyStore: keyStore,
            maintenanceDate: now()
        )
        database = resolution.database
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: resolution.database,
            faultInjector: faultInjector,
            appBuild: appBuild
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
            faultInjector: faultInjector,
            appBuild: appBuild
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

    func publishMutation() {
        notificationCenter.post(
            name: .clipboardHistoryV2DidMutate,
            object: nil
        )
    }

    func installCaptureMonitorForTesting(
        _ monitor: ClipboardHistoryCaptureMonitor
    ) {
        captureMonitor = monitor
    }
}

extension ClipboardHistoryModule {
    /// The live pool, for reads and for code that has already had its write
    /// turn. A synchronous write issued from this actor resolves the pool
    /// through `writableDatabase()` instead, or it parks the actor behind a
    /// search index rebuild.
    func requiredDatabase() throws -> DatabasePool {
        guard availability == .ready, let database else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        return database
    }

    /// The live pool for a write issued from this actor, resolved once the
    /// caller's write turn comes up (see `waitForWriteTurn()`).
    ///
    /// Retry and close can replace or remove the pool while the caller
    /// waits, so it is only looked up afterwards, and any other actor state
    /// read before this call must be read again. A reset meanwhile fails the
    /// call instead.
    func writableDatabase() async throws -> DatabasePool {
        try await waitForWriteTurn()
        return try requiredDatabase()
    }

    /// Whether `waitForWriteTurn()` would suspend right now.
    var mustWaitForWriteTurn: Bool {
        searchIndexRebuildTask != nil || nextWriteTurn != currentWriteTurn
    }

    /// Suspends until no search index rebuild is in flight and every writer
    /// that arrived earlier has had its turn; returns at once otherwise.
    ///
    /// A rebuild holds the pool's writer for one long transaction, about a
    /// minute on a large store. A synchronous `write` issued on this actor
    /// meanwhile parks the actor's thread on the writer queue, and every read
    /// queued behind it (history pages, counts, status) stalls with it.
    /// Waiting here suspends the actor instead, so it keeps serving reads
    /// from the WAL. Turns are served in arrival order, because a finished
    /// task resumes everything awaiting it in no particular order and the
    /// writes queued behind a rebuild would otherwise commit out of order.
    /// A turn covers the caller's code up to its next suspension point; it
    /// does not hold later writers back while an asynchronous write is in
    /// flight.
    ///
    /// Throws `storeUnavailable` when a reset replaced the store while the
    /// caller waited: what it was about to write belongs to the history the
    /// reset discarded, so it must not land in the store that replaced it.
    func waitForWriteTurn() async throws {
        guard mustWaitForWriteTurn else { return }
        let epoch = storeEpoch
        let turn = nextWriteTurn
        nextWriteTurn += 1
        while true {
            if let rebuild = searchIndexRebuildTask {
                _ = await rebuild.value
                // A retry or reset may have started another one meanwhile.
                if searchIndexRebuildTask == rebuild {
                    searchIndexRebuildTask = nil
                }
            } else if currentWriteTurn != turn {
                await withCheckedContinuation { waiter in
                    writeTurnWaiters.append(waiter)
                }
            } else {
                break
            }
        }
        currentWriteTurn += 1
        let waiters = writeTurnWaiters
        writeTurnWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard storeEpoch == epoch else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
    }

    /// Test-only teardown: releases an installed capture monitor, stops
    /// background work, waits for a search index rebuild and closes the pool.
    /// A call after a completed close is a no-op, so a test that closes
    /// mid-test can leave the final close to its teardown. A call while
    /// another close is still running throws `operationUnavailable`.
    func closeStoreForTesting() async throws {
        guard !isClosingStore else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        isClosingStore = true
        // The monitor holds this module strongly. Drop it before the first
        // suspension, so a reentrant caller cannot reuse a monitor that is
        // being torn down. A setMonitoring call during or after the close
        // installs a new monitor that this close does not release, so tests
        // stop their lifecycle before closing the module.
        if let monitor = captureMonitor {
            captureMonitor = nil
            monitoringEnabled = false
            monitoringRequested = false
            await monitor.setEnabled(false)
        }
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

        return openStore(
            at: root,
            keys: ClipboardHistoryKeyDerivation.deriveV1(from: masterKey),
            maintenanceDate: maintenanceDate
        )
    }

    /// Opens (or creates) the store at `root` with keys already loaded.
    static func openStore(
        at root: URL,
        keys: ClipboardHistoryDerivedKeys,
        maintenanceDate: Date
    ) -> StoreResolution {
        do {
            try prepareStoreDirectories(at: root)

            let database = try openDatabase(
                at: databaseURL(in: root),
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
            let requiresMigration = try database.read { database in
                try !migrator.hasCompletedMigrations(database)
            }
            if let migrationTarget {
                try migrator.migrate(database, upTo: migrationTarget)
            } else {
                try migrator.migrate(database)
                try prepareSearchIndexState(in: database)
            }
            // Re-validate only when this open actually wrote schema. An
            // already-current store was validated above, and integrity_check
            // reads every page of the (trigram-index-heavy) database — running
            // it twice is the dominant cost of opening a large history, and
            // this runs synchronously during AppDelegate.init.
            if requiresMigration {
                try validateIntegrity(of: database)
            }
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
