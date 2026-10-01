import ClipboardHistory
import Foundation
import Observation
import os

private let logger = Logger(
    subsystem: "dev.bybee.AnyDoor",
    category: "clipboardHistory.lifecycle"
)

enum ClipboardHistoryLifecycleState: Equatable {
    case preparing
    case migrating
    case ready
    case paused(ClipboardHistoryStatus.AvailabilityReason?)
    case storeUnavailable(ClipboardHistoryStatus.AvailabilityReason?)
    case migrationFailed
    case resetFailed
}

extension ClipboardHistoryLifecycleState {
    /// Whether this state leaves an explicit capture (a screenshot, recognized
    /// text, a QR code or a picked color) to the store. While the lifecycle
    /// prepares, migrates or has failed to migrate, the store can already be
    /// open but has to stay empty: the pre-v2 migration refuses a store that
    /// already holds entries, so one early capture would block it for good.
    /// Every other state leaves the decision to the store, which refuses a
    /// capture itself while it is not open.
    var leavesExplicitCapturesToTheStore: Bool {
        switch self {
        case .preparing, .migrating, .migrationFailed:
            return false
        case .ready, .paused, .storeUnavailable, .resetFailed:
            return true
        }
    }
}

enum ClipboardHistoryMigrationPreparation: Equatable {
    case proceed
    case suspendForRelaunch
}

struct ClipboardHistoryLifecycleOperations: Sendable {
    let status: @Sendable () async -> ClipboardHistoryStatus
    let setMonitoring:
        @Sendable (
            ClipboardHistoryMonitoringCommand,
            ClipboardHistoryMonitoringConfiguration
        ) async -> ClipboardHistoryStatus
    let legacyMigrationPublicationState:
        @Sendable () async throws
            -> ClipboardHistoryLegacyMigrationPublicationState
    let migrate:
        @Sendable (
            ClipboardHistoryLegacyMigrationRequest
        ) async throws -> ClipboardHistoryLegacyMigrationOutcome
    let cleanupLegacyPayloads:
        @Sendable (URL) async throws
            -> ClipboardHistoryLegacyCleanupReport
    let retryStore: @Sendable () async -> Void
    let resetStore: @Sendable () async throws -> Void

    init(module: ClipboardHistoryModule) {
        status = {
            await module.status()
        }
        setMonitoring = { command, configuration in
            await module.setMonitoring(
                command,
                configuration: configuration
            )
        }
        legacyMigrationPublicationState = {
            try await module.legacyMigrationPublicationState()
        }
        migrate = { request in
            try await module.migrateLegacy(request)
        }
        cleanupLegacyPayloads = { payloadDirectory in
            try await module.cleanupLegacyPayloads(in: payloadDirectory)
        }
        retryStore = {
            await module.retry()
        }
        resetStore = {
            try await module.reset(confirmation: .confirmed)
        }
    }

    init(
        status: @escaping @Sendable () async -> ClipboardHistoryStatus,
        setMonitoring:
            @escaping @Sendable (
                ClipboardHistoryMonitoringCommand,
                ClipboardHistoryMonitoringConfiguration
            ) async -> ClipboardHistoryStatus,
        legacyMigrationPublicationState:
            @escaping @Sendable () async throws
                -> ClipboardHistoryLegacyMigrationPublicationState,
        migrate:
            @escaping @Sendable (
                ClipboardHistoryLegacyMigrationRequest
            ) async throws -> ClipboardHistoryLegacyMigrationOutcome,
        cleanupLegacyPayloads:
            @escaping @Sendable (URL) async throws
                -> ClipboardHistoryLegacyCleanupReport,
        retryStore: @escaping @Sendable () async -> Void,
        resetStore: @escaping @Sendable () async throws -> Void
    ) {
        self.status = status
        self.setMonitoring = setMonitoring
        self.legacyMigrationPublicationState =
            legacyMigrationPublicationState
        self.migrate = migrate
        self.cleanupLegacyPayloads = cleanupLegacyPayloads
        self.retryStore = retryStore
        self.resetStore = resetStore
    }
}

@MainActor
@Observable
final class ClipboardHistoryLifecycle {
    private let operations: ClipboardHistoryLifecycleOperations
    private let defaults: UserDefaults
    private let migrationPreparation:
        @MainActor () async throws -> ClipboardHistoryMigrationPreparation
    private let migrationRequest:
        (@MainActor () throws -> ClipboardHistoryLegacyMigrationRequest)?
    private let legacyCleanupState:
        @MainActor () throws -> ClipboardHistoryLegacyCleanupState
    private let legacyPayloadDirectory: (@MainActor () -> URL)?
    private let finishMigration: @MainActor () throws -> Void
    private let retrySnapshotDeletion: @MainActor () throws -> Void
    private let isKeychainUnlocked: @Sendable () -> Bool?
    private let keychainUnlockPollInterval: Duration
    private let unlockNotifications: NotificationCenter

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var keychainUnlockWatch: Task<Void, Never>?
    @ObservationIgnored private var screenUnlockObserver: (any NSObjectProtocol)?

    private(set) var state: ClipboardHistoryLifecycleState = .preparing
    private(set) var migrationReport:
        ClipboardHistoryLegacyMigrationReport?
    /// Set once this process has seen the pre-v2 cutover complete. A cutover
    /// never comes undone, so the `.preparing` pass of a later retry does not
    /// hold explicit captures back.
    @ObservationIgnored private var hasConfirmedLegacyCutover = false

    /// Whether an explicit capture may be written to history now. See
    /// `ClipboardHistoryLifecycleState.leavesExplicitCapturesToTheStore`.
    var admitsExplicitCaptures: Bool {
        hasConfirmedLegacyCutover || state.leavesExplicitCapturesToTheStore
    }

    init(
        module: ClipboardHistoryModule,
        defaults: UserDefaults = .standard,
        migrationPreparation:
            @escaping @MainActor () async throws
                -> ClipboardHistoryMigrationPreparation = { .proceed },
        legacyCleanupState:
            (@MainActor () throws
                -> ClipboardHistoryLegacyCleanupState)? = nil,
        legacyPayloadDirectory: (@MainActor () -> URL)? = nil,
        migrationRequest:
            (@MainActor () throws
                -> ClipboardHistoryLegacyMigrationRequest)?,
        finishMigration: @escaping @MainActor () throws -> Void = {},
        retrySnapshotDeletion:
            @escaping @MainActor () throws -> Void = {}
    ) {
        operations = ClipboardHistoryLifecycleOperations(module: module)
        self.defaults = defaults
        self.migrationPreparation = migrationPreparation
        self.migrationRequest = migrationRequest
        self.legacyCleanupState =
            legacyCleanupState
            ?? { migrationRequest == nil ? .completed : .incomplete }
        self.legacyPayloadDirectory = legacyPayloadDirectory
        self.finishMigration = finishMigration
        self.retrySnapshotDeletion = retrySnapshotDeletion
        isKeychainUnlocked = {
            ClipboardHistoryKeychainLock.isLoginKeychainUnlocked()
        }
        keychainUnlockPollInterval = Self.defaultKeychainUnlockPollInterval
        unlockNotifications = DistributedNotificationCenter.default()
    }

    init(
        operations: ClipboardHistoryLifecycleOperations,
        defaults: UserDefaults,
        migrationPreparation:
            @escaping @MainActor () async throws
                -> ClipboardHistoryMigrationPreparation = { .proceed },
        legacyCleanupState:
            (@MainActor () throws
                -> ClipboardHistoryLegacyCleanupState)? = nil,
        legacyPayloadDirectory: (@MainActor () -> URL)? = nil,
        migrationRequest:
            (@MainActor () throws
                -> ClipboardHistoryLegacyMigrationRequest)?,
        finishMigration: @escaping @MainActor () throws -> Void = {},
        retrySnapshotDeletion:
            @escaping @MainActor () throws -> Void = {},
        isKeychainUnlocked: @escaping @Sendable () -> Bool? = {
            ClipboardHistoryKeychainLock.isLoginKeychainUnlocked()
        },
        keychainUnlockPollInterval: Duration =
            ClipboardHistoryLifecycle.defaultKeychainUnlockPollInterval,
        unlockNotifications: NotificationCenter =
            DistributedNotificationCenter.default()
    ) {
        self.operations = operations
        self.defaults = defaults
        self.migrationPreparation = migrationPreparation
        self.migrationRequest = migrationRequest
        self.legacyCleanupState =
            legacyCleanupState
            ?? { migrationRequest == nil ? .completed : .incomplete }
        self.legacyPayloadDirectory = legacyPayloadDirectory
        self.finishMigration = finishMigration
        self.retrySnapshotDeletion = retrySnapshotDeletion
        self.isKeychainUnlocked = isKeychainUnlocked
        self.keychainUnlockPollInterval = keychainUnlockPollInterval
        self.unlockNotifications = unlockNotifications
    }

    /// Slow enough to be free, quick enough that unlocking the keychain and
    /// copying something right after still lands in history.
    static let defaultKeychainUnlockPollInterval: Duration = .seconds(5)

    func start() {
        launch(retryStoreFirst: false, resetStoreFirst: false)
    }

    func retry() {
        let retriesStore: Bool
        switch state {
        case .storeUnavailable, .paused, .resetFailed:
            retriesStore = true
        case .migrationFailed:
            retriesStore = false
        case .preparing, .migrating, .ready:
            return
        }
        launch(
            retryStoreFirst: retriesStore,
            resetStoreFirst: false
        )
    }

    func resetConfirmed() {
        switch state {
        case .storeUnavailable(.storeRelocationFailed):
            // The history is intact, in the pre-v2 folder or a stopped move's
            // staging folder; a reset would only destroy it. Retry finishes
            // the move instead.
            return
        case .storeUnavailable, .resetFailed:
            break
        case .preparing, .migrating, .ready, .paused, .migrationFailed:
            return
        }
        launch(retryStoreFirst: false, resetStoreFirst: true)
    }

    func setMonitoringEnabled(_ enabled: Bool) async {
        ClipboardPreferences.setMonitoringEnabled(enabled, in: defaults)
        let configuration = ClipboardPreferences.monitoringConfiguration(
            from: defaults
        )
        guard state == .ready else {
            if !enabled {
                _ = await operations.setMonitoring(.stop, configuration)
            }
            return
        }
        _ = await operations.setMonitoring(
            enabled ? .start : .stop,
            configuration
        )
    }

    func refreshMonitoringConfiguration() async {
        let configuration = ClipboardPreferences.monitoringConfiguration(
            from: defaults
        )
        let command: ClipboardHistoryMonitoringCommand =
            state == .ready
                && ClipboardPreferences.monitoringEnabled(from: defaults)
                ? .start
                : .stop
        _ = await operations.setMonitoring(command, configuration)
    }

    /// Stops observation for termination. The in-flight operation is cancelled
    /// but deliberately **not** awaited: a migration performs uninterruptible
    /// database work, so awaiting it would stall Quit for as long as the legacy
    /// history takes to convert. The cutover is crash-safe by construction (the
    /// snapshot survives, and the completion marker is fsynced only after
    /// publication and verified cleanup), so quitting mid-migration is safe and
    /// simply resumes on the next launch.
    func stop() async {
        generation += 1
        operationTask?.cancel()
        operationTask = nil
        keychainUnlockWatch?.cancel()
        keychainUnlockWatch = nil
        if let screenUnlockObserver {
            unlockNotifications.removeObserver(screenUnlockObserver)
            self.screenUnlockObserver = nil
        }
        _ = await operations.setMonitoring(
            .stop,
            ClipboardPreferences.monitoringConfiguration(from: defaults)
        )
    }

    func awaitCurrentOperationForTesting() async {
        await operationTask?.value
    }

    /// The notification macOS actually posts when the session comes back — in
    /// practice a keychain locks because the screen locked, and it is that
    /// unlock, not a `security lock-keychain`, that restores access.
    static let screenUnlockNotification = Notification.Name(
        "com.apple.screenIsUnlocked"
    )

    /// The login keychain can lock while an already-open store still holds its
    /// key in memory, and nothing in-process reports that transition. Poll its
    /// lock flag while ready so capture pauses promptly, then watch for unlock
    /// and retry the store from a fresh baseline.
    ///
    /// Two signals because neither covers the other: the screen-unlock
    /// notification is the one that fires in the real scenario, and the lock
    /// state poll also catches a keychain locked on its own (a timeout, or
    /// `security lock-keychain`). Neither ever reads the keychain *item* — that
    /// would re-raise the password prompt every few seconds.
    private func updateKeychainUnlockWatch() {
        let watchesLockState = state == .ready
            || state == .paused(.keychainLocked)
        guard watchesLockState else {
            keychainUnlockWatch?.cancel()
            keychainUnlockWatch = nil
            if let screenUnlockObserver {
                unlockNotifications.removeObserver(screenUnlockObserver)
                self.screenUnlockObserver = nil
            }
            return
        }
        if state == .ready, let screenUnlockObserver {
            unlockNotifications.removeObserver(screenUnlockObserver)
            self.screenUnlockObserver = nil
        }
        if state == .paused(.keychainLocked), screenUnlockObserver == nil {
            screenUnlockObserver = unlockNotifications.addObserver(
                forName: Self.screenUnlockNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                        case .paused(.keychainLocked) = self.state
                    else {
                        return
                    }
                    self.retry()
                }
            }
        }
        guard keychainUnlockWatch == nil else { return }
        let probe = isKeychainUnlocked
        let interval = keychainUnlockPollInterval
        keychainUnlockWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                switch state {
                case .ready:
                    guard probe() == false else { continue }
                    state = .paused(.keychainLocked)
                    _ = await operations.setMonitoring(
                        .stop,
                        ClipboardPreferences.monitoringConfiguration(
                            from: defaults
                        )
                    )
                    updateKeychainUnlockWatch()
                case .paused(.keychainLocked):
                    guard probe() == true else { continue }
                    keychainUnlockWatch = nil
                    retry()
                    return
                case .preparing, .migrating, .storeUnavailable,
                    .migrationFailed, .resetFailed, .paused:
                    return
                }
            }
        }
    }

    private func launch(
        retryStoreFirst: Bool,
        resetStoreFirst: Bool
    ) {
        guard operationTask == nil else { return }
        generation += 1
        let requestGeneration = generation
        state = .preparing
        updateKeychainUnlockWatch()
        operationTask = Task { @concurrent [weak self] in
            await self?.run(
                generation: requestGeneration,
                retryStoreFirst: retryStoreFirst,
                resetStoreFirst: resetStoreFirst
            )
        }
    }

    private func run(
        generation requestGeneration: Int,
        retryStoreFirst: Bool,
        resetStoreFirst: Bool
    ) async {
        defer {
            if generation == requestGeneration {
                operationTask = nil
                updateKeychainUnlockWatch()
            }
        }
        do {
            guard try await migrationPreparation() == .proceed else {
                return
            }
        } catch {
            guard generation == requestGeneration else { return }
            logger.error(
                "Preparing the Clipboard History migration failed: \(Self.logName(of: error), privacy: .public)"
            )
            state = .migrationFailed
            return
        }
        guard !Task.isCancelled, generation == requestGeneration else {
            return
        }
        if resetStoreFirst {
            do {
                try await operations.resetStore()
            } catch {
                guard generation == requestGeneration else { return }
                logger.error(
                    "Resetting Clipboard History failed: \(Self.logName(of: error), privacy: .public)"
                )
                state = .resetFailed
                return
            }
        } else if retryStoreFirst {
            await operations.retryStore()
        }
        guard !Task.isCancelled, generation == requestGeneration else {
            return
        }

        let status = await operations.status()
        guard !Task.isCancelled, generation == requestGeneration else {
            return
        }
        switch status.availability {
        case .ready:
            break
        case .paused:
            state = .paused(status.reason)
            return
        case .unavailable:
            state = .storeUnavailable(status.reason)
            return
        }

        let configuration = ClipboardPreferences.monitoringConfiguration(
            from: defaults
        )
        let cleanupState: ClipboardHistoryLegacyCleanupState
        do {
            cleanupState = try legacyCleanupState()
        } catch {
            logger.error(
                "Reading the Clipboard History cutover state failed: \(Self.logName(of: error), privacy: .public)"
            )
            state = .migrationFailed
            return
        }
        guard cleanupState != .completed else {
            hasConfirmedLegacyCutover = true
            state = .ready
            if ClipboardPreferences.monitoringEnabled(from: defaults) {
                _ = await operations.setMonitoring(.start, configuration)
            }
            return
        }
        _ = await operations.setMonitoring(
            .migrationStarted,
            configuration
        )
        guard !Task.isCancelled, generation == requestGeneration else {
            return
        }
        state = .migrating
        do {
            if cleanupState == .snapshotDeletionPending {
                try retrySnapshotDeletion()
            } else {
                let publicationState =
                    try await operations
                    .legacyMigrationPublicationState()
                let payloadDirectory: URL
                switch publicationState {
                case .published(let report):
                    migrationReport = report
                    guard let legacyPayloadDirectory else {
                        throw ClipboardHistoryModuleError
                            .legacyCleanupFailed
                    }
                    payloadDirectory = legacyPayloadDirectory()
                case .notPublished:
                    guard let migrationRequest else {
                        throw ClipboardHistoryModuleError
                            .legacyMigrationFailed
                    }
                    let migrationSource = try migrationRequest()
                    let request: ClipboardHistoryLegacyMigrationRequest
                    if resetStoreFirst {
                        request = ClipboardHistoryLegacyMigrationRequest(
                            transfer: ClipboardHistoryLegacyTransfer(
                                entries: [],
                                tags: [],
                                categoryOrder: [],
                                retentionPeriod: .default
                            ),
                            payloadDirectory:
                                migrationSource.payloadDirectory
                        )
                    } else {
                        request = migrationSource
                    }
                    let outcome = try await operations.migrate(request)
                    guard !Task.isCancelled,
                        generation == requestGeneration
                    else {
                        return
                    }
                    switch outcome {
                    case .published(let report),
                        .alreadyPublished(let report):
                        migrationReport = report
                    }
                    payloadDirectory = request.payloadDirectory
                }
                let cleanupReport =
                    try await operations.cleanupLegacyPayloads(
                        payloadDirectory
                    )
                guard cleanupReport.canDeleteLegacyRows else {
                    throw ClipboardHistoryModuleError
                        .legacyCleanupFailed
                }
                guard !Task.isCancelled,
                    generation == requestGeneration
                else {
                    return
                }
                try finishMigration()
            }
            hasConfirmedLegacyCutover = true
            _ = await operations.setMonitoring(
                .migrationCompleted,
                configuration
            )
            guard !Task.isCancelled, generation == requestGeneration else {
                return
            }
            state = .ready
            if ClipboardPreferences.monitoringEnabled(from: defaults) {
                _ = await operations.setMonitoring(.start, configuration)
            }
        } catch {
            guard generation == requestGeneration else { return }
            logger.error(
                "The Clipboard History migration failed: \(Self.logName(of: error), privacy: .public)"
            )
            state = .migrationFailed
        }
    }

    /// Names `error` for the log by what failed, never by what it carries:
    /// a payload or a Foundation error's description can include a file
    /// path. The app's own errors are named by type and case, every other
    /// error by its domain and code.
    nonisolated static func logName(of error: any Error) -> String {
        switch error {
        case let error as ClipboardHistoryLegacySourceError:
            // Its only payload is an errno.
            return "ClipboardHistoryLegacySourceError.\(error)"
        case let error as ClipboardHistoryModuleError:
            // Some cases carry a URL or entry identifiers.
            let caseName = String(describing: error).prefix { $0 != "(" }
            return "ClipboardHistoryModuleError.\(caseName)"
        default:
            let error = error as NSError
            return "\(error.domain) \(error.code)"
        }
    }
}

extension ClipboardHistoryLifecycle {
    /// The lifecycle the app runs. The one-time pre-v2 migration keeps its
    /// SwiftData snapshot and cutover marker in `applicationDataDirectory`
    /// (`Application Support/dev.bybee.AnyDoor` in production) and reads
    /// pre-v2 payloads from `ClipboardHistoryModule.legacyPayloadDirectory`,
    /// never from the v2 store root: reading them from the store would carry
    /// every legacy image over without its content.
    static func production(
        module: ClipboardHistoryModule,
        applicationDataDirectory: URL,
        defaults: UserDefaults = .standard,
        migrationPreparation:
            @escaping @MainActor () async throws
                -> ClipboardHistoryMigrationPreparation
    ) -> ClipboardHistoryLifecycle {
        let productionStoreURL = applicationDataDirectory
            .appendingPathComponent("AnyDoor.store")
        let legacyPayloadDirectory = ClipboardHistoryModule
            .legacyPayloadDirectory(in: applicationDataDirectory)
        return ClipboardHistoryLifecycle(
            module: module,
            defaults: defaults,
            migrationPreparation: migrationPreparation,
            legacyCleanupState: {
                ClipboardHistoryLegacySource.cleanupState(
                    in: applicationDataDirectory
                )
            },
            legacyPayloadDirectory: {
                ClipboardHistoryLegacySource.snapshotPayloadDirectory(
                    in: applicationDataDirectory
                )
            },
            migrationRequest: {
                let source =
                    try ClipboardHistoryLegacySource.openForMigration(
                        applicationSupportDirectory: applicationDataDirectory,
                        productionStoreURL: productionStoreURL,
                        payloadDirectory: legacyPayloadDirectory
                    )
                return try source.makeMigrationRequest(defaults: defaults)
            },
            finishMigration: {
                try ClipboardHistoryLegacySource.finishMigration(
                    in: applicationDataDirectory
                )
            },
            retrySnapshotDeletion: {
                try ClipboardHistoryLegacySource.retrySnapshotDeletion(
                    in: applicationDataDirectory
                )
            }
        )
    }
}

/// The recovery affordance a stalled lifecycle state offers in Settings: the
/// line that explains it, and whether the destructive reset is one of the ways
/// out. Kept out of the `@ViewBuilder` so the mapping can be pinned by a test —
/// a state that silently borrows another state's line reads to the user as
/// nothing having happened at all.
struct ClipboardLifecycleRecovery: Equatable {
    let message: L10n.Key
    let includesReset: Bool

    init?(state: ClipboardHistoryLifecycleState) {
        switch state {
        case .migrationFailed:
            self.init(
                message: .settingsClipboardMigrationFailed,
                includesReset: false
            )
        case .storeUnavailable(.storeRelocationFailed):
            // The store could not be moved to its new folder but is intact;
            // a reset would destroy it, and a retry finishes the move once
            // the cause is gone.
            self.init(
                message: .settingsClipboardRelocationFailed,
                includesReset: false
            )
        case .storeUnavailable:
            self.init(
                message: .settingsClipboardStoreUnavailable,
                includesReset: true
            )
        case .resetFailed:
            // Reset stays offered: the cause is usually external (permissions,
            // a full disk) and clears without the app restarting.
            self.init(
                message: .settingsClipboardResetFailed,
                includesReset: true
            )
        case .paused:
            // A locked keychain resolves itself; offering a reset here is how a
            // user wipes their own history over a temporary lock.
            self.init(
                message: .settingsClipboardStorePaused,
                includesReset: false
            )
        case .preparing, .migrating, .ready:
            return nil
        }
    }

    private init(message: L10n.Key, includesReset: Bool) {
        self.message = message
        self.includesReset = includesReset
    }
}
