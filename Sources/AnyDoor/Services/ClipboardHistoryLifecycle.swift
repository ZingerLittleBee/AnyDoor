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
    let migrate:
        @Sendable (
            ClipboardHistoryLegacyMigrationRequest
        ) async throws -> ClipboardHistoryLegacyMigrationOutcome
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
        migrate = { request in
            try await module.migrateLegacy(request)
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
        migrate:
            @escaping @Sendable (
                ClipboardHistoryLegacyMigrationRequest
            ) async throws -> ClipboardHistoryLegacyMigrationOutcome,
        retryStore: @escaping @Sendable () async -> Void,
        resetStore: @escaping @Sendable () async throws -> Void
    ) {
        self.status = status
        self.setMonitoring = setMonitoring
        self.migrate = migrate
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
        @MainActor () throws -> ClipboardHistoryLegacyMigrationRequest

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    private(set) var state: ClipboardHistoryLifecycleState = .preparing
    private(set) var migrationReport:
        ClipboardHistoryLegacyMigrationReport?

    init(
        module: ClipboardHistoryModule,
        defaults: UserDefaults = .standard,
        migrationRequest:
            @escaping @MainActor () throws
                -> ClipboardHistoryLegacyMigrationRequest
    ) {
        operations = ClipboardHistoryLifecycleOperations(module: module)
        self.defaults = defaults
        self.migrationRequest = migrationRequest
    }

    init(
        operations: ClipboardHistoryLifecycleOperations,
        defaults: UserDefaults,
        migrationRequest:
            @escaping @MainActor () throws
                -> ClipboardHistoryLegacyMigrationRequest
    ) {
        self.operations = operations
        self.defaults = defaults
        self.migrationRequest = migrationRequest
    }

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

    func stop() async {
        generation += 1
        let task = operationTask
        operationTask = nil
        task?.cancel()
        await task?.value
        _ = await operations.setMonitoring(
            .stop,
            ClipboardPreferences.monitoringConfiguration(from: defaults)
        )
    }

    func awaitCurrentOperationForTesting() async {
        await operationTask?.value
    }

    private func launch(
        retryStoreFirst: Bool,
        resetStoreFirst: Bool
    ) {
        guard operationTask == nil else { return }
        generation += 1
        let requestGeneration = generation
        state = .preparing
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
        _ = await operations.setMonitoring(
            .migrationStarted,
            configuration
        )
        guard !Task.isCancelled, generation == requestGeneration else {
            return
        }
        state = .migrating
        do {
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
            guard !Task.isCancelled, generation == requestGeneration else {
                return
            }
            switch outcome {
            case .published(let report), .alreadyPublished(let report):
                migrationReport = report
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
