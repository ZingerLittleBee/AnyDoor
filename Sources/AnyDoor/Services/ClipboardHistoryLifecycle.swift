import ClipboardHistory
import Foundation
import Observation

enum ClipboardHistoryLifecycleState: Equatable {
    case preparing
    case migrating
    case ready
    case paused(ClipboardHistoryStatus.AvailabilityReason?)
    case storeUnavailable(ClipboardHistoryStatus.AvailabilityReason?)
    case migrationFailed
    case resetFailed
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

    init(
        module: ClipboardHistoryModule,
        defaults: UserDefaults = .standard,
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
        guard case .storeUnavailable = state else { return }
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

    /// A locked keychain is the one stalled state the user fixes outside
    /// AnyDoor, and nothing in-process tells the app when that happens — so
    /// while it lasts, watch for the unlock two ways and retry the store on the
    /// first sign of it. Without this the store stays paused until the next
    /// launch, which turns a self-healing state into one that silently drops
    /// everything the user copies after unlocking.
    ///
    /// Two signals because neither covers the other: the screen-unlock
    /// notification is the one that fires in the real scenario, and the lock
    /// state poll also catches a keychain locked on its own (a timeout, or
    /// `security lock-keychain`). Neither ever reads the keychain *item* — that
    /// would re-raise the password prompt every few seconds.
    private func updateKeychainUnlockWatch() {
        guard case .paused(.keychainLocked) = state else {
            keychainUnlockWatch?.cancel()
            keychainUnlockWatch = nil
            if let screenUnlockObserver {
                unlockNotifications.removeObserver(screenUnlockObserver)
                self.screenUnlockObserver = nil
            }
            return
        }
        if screenUnlockObserver == nil {
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
                guard case .paused(.keychainLocked) = state else { return }
                guard probe() == true else { continue }
                keychainUnlockWatch = nil
                retry()
                return
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
        if resetStoreFirst {
            do {
                try await operations.resetStore()
            } catch {
                guard generation == requestGeneration else { return }
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
            state = .migrationFailed
            return
        }
        guard cleanupState != .completed else {
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
            state = .migrationFailed
        }
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
