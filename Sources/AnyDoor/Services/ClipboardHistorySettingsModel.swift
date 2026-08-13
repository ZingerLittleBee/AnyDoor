import ClipboardHistory
import Foundation
import Observation

struct ClipboardHistoryRetentionConfirmation: Identifiable {
    let period: ClipboardHistoryRetentionPeriod
    let preview: ClipboardHistoryDestructivePreview

    var id: String {
        "\(period.rawValue)-\(preview.affectedCount)"
    }
}

struct ClipboardHistoryClearConfirmation: Identifiable {
    let scope: ClipboardHistoryClearScope
    let preview: ClipboardHistoryDestructivePreview

    var id: String {
        "\(scope.rawValue)-\(preview.affectedCount)"
    }
}

struct ClipboardHistorySettingsRefreshOperations: Sendable {
    let retentionPeriod:
        @Sendable () async throws -> ClipboardHistoryRetentionPeriod
    let automaticImageTextIndexingEnabled:
        @Sendable () async throws -> Bool
    let storageUsage: @Sendable () async throws -> UInt64

    init(module: ClipboardHistoryModule) {
        retentionPeriod = {
            try await module.retentionStatus().period
        }
        automaticImageTextIndexingEnabled = {
            try await module.isAutomaticImageTextIndexingEnabled()
        }
        storageUsage = {
            try await module.storageUsage()
        }
    }

    init(
        retentionPeriod:
            @escaping @Sendable () async throws
                -> ClipboardHistoryRetentionPeriod,
        automaticImageTextIndexingEnabled:
            @escaping @Sendable () async throws -> Bool,
        storageUsage:
            @escaping @Sendable () async throws -> UInt64
    ) {
        self.retentionPeriod = retentionPeriod
        self.automaticImageTextIndexingEnabled =
            automaticImageTextIndexingEnabled
        self.storageUsage = storageUsage
    }
}

@MainActor
@Observable
final class ClipboardHistorySettingsModel {
    private let module: ClipboardHistoryModule
    let lifecycle: ClipboardHistoryLifecycle
    private let presentation: SettingsPresentation
    private let defaults: UserDefaults
    private let refreshOperations:
        ClipboardHistorySettingsRefreshOperations
    @ObservationIgnored private var latestSettingsAppearanceGeneration:
        UInt64 = 0
    @ObservationIgnored private var settingsAppearanceRefreshTask:
        Task<Void, Never>?

    private(set) var retention: ClipboardHistoryRetentionPeriod = .default
    private(set) var automaticImageTextIndexingEnabled = false
    private(set) var storageBytes: UInt64 = 0
    private(set) var operationFailed = false
    private(set) var retentionConfirmation:
        ClipboardHistoryRetentionConfirmation?
    private(set) var clearConfirmation: ClipboardHistoryClearConfirmation?

    var monitoringEnabled: Bool
    var copyOnly: Bool
    var ignoresUniversalClipboard: Bool
    var excludedBundleIDs: [String]
    var clearIncludesProtected = false

    init(
        module: ClipboardHistoryModule,
        lifecycle: ClipboardHistoryLifecycle,
        presentation: SettingsPresentation,
        defaults: UserDefaults = .standard,
        refreshOperations: ClipboardHistorySettingsRefreshOperations? = nil
    ) {
        self.module = module
        self.lifecycle = lifecycle
        self.presentation = presentation
        self.defaults = defaults
        self.refreshOperations =
            refreshOperations
            ?? ClipboardHistorySettingsRefreshOperations(module: module)
        monitoringEnabled = ClipboardPreferences.monitoringEnabled(
            from: defaults
        )
        copyOnly = ClipboardPreferences.copyOnly(from: defaults)
        ignoresUniversalClipboard =
            ClipboardPreferences.ignoresUniversalClipboard(from: defaults)
        excludedBundleIDs = ClipboardPreferences.excludedBundleIDs(
            from: defaults
        )
    }

    func refresh() async {
        await refresh(expectedSettingsAppearanceGeneration: nil)
    }

    /// Refreshes only while Clipboard is the selected Settings pane. The model
    /// owns the underlying task so a newer presentation can cancel a suspended
    /// read even when the storage boundary does not complete immediately.
    func refreshForSettingsPresentation() async {
        guard presentation.selectedTab == .clipboard else {
            settingsAppearanceRefreshTask?.cancel()
            settingsAppearanceRefreshTask = nil
            return
        }
        let generation = presentation.showGeneration
        guard generation > latestSettingsAppearanceGeneration else { return }
        latestSettingsAppearanceGeneration = generation
        settingsAppearanceRefreshTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh(
                expectedSettingsAppearanceGeneration: generation
            )
        }
        settingsAppearanceRefreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if latestSettingsAppearanceGeneration == generation {
            settingsAppearanceRefreshTask = nil
        }
    }

    private func refresh(
        expectedSettingsAppearanceGeneration: UInt64?
    ) async {
        do {
            guard shouldApplyRefresh(
                expectedSettingsAppearanceGeneration
            ) else { return }
            let retention = try await refreshOperations.retentionPeriod()
            guard shouldApplyRefresh(
                expectedSettingsAppearanceGeneration
            ) else { return }
            let automaticImageTextIndexingEnabled =
                try await refreshOperations
                    .automaticImageTextIndexingEnabled()
            guard shouldApplyRefresh(
                expectedSettingsAppearanceGeneration
            ) else { return }
            let storageBytes = try await refreshOperations.storageUsage()
            guard shouldApplyRefresh(
                expectedSettingsAppearanceGeneration
            ) else { return }
            self.retention = retention
            self.automaticImageTextIndexingEnabled =
                automaticImageTextIndexingEnabled
            self.storageBytes = storageBytes
            operationFailed = false
        } catch {
            guard shouldApplyRefresh(
                expectedSettingsAppearanceGeneration
            ) else { return }
            operationFailed = failureIsReportable
        }
        guard shouldApplyRefresh(expectedSettingsAppearanceGeneration)
        else { return }
        reloadLocalPreferences()
    }

    private func shouldApplyRefresh(
        _ expectedSettingsAppearanceGeneration: UInt64?
    ) -> Bool {
        !Task.isCancelled && (
            expectedSettingsAppearanceGeneration == nil
                || expectedSettingsAppearanceGeneration
                    == latestSettingsAppearanceGeneration
        )
    }

    func setMonitoringEnabled(_ enabled: Bool) async {
        monitoringEnabled = enabled
        await lifecycle.setMonitoringEnabled(enabled)
    }

    func setCopyOnly(_ enabled: Bool) {
        copyOnly = enabled
        ClipboardPreferences.setCopyOnly(enabled, in: defaults)
    }

    func setIgnoresUniversalClipboard(_ ignored: Bool) async {
        ignoresUniversalClipboard = ignored
        ClipboardPreferences.setIgnoresUniversalClipboard(
            ignored,
            in: defaults
        )
        await lifecycle.refreshMonitoringConfiguration()
    }

    func setAutomaticImageTextIndexingEnabled(_ enabled: Bool) async {
        do {
            try await module.setAutomaticImageTextIndexingEnabled(enabled)
            automaticImageTextIndexingEnabled = enabled
            operationFailed = false
        } catch {
            operationFailed = true
        }
    }

    func prepareRetentionChange(
        to period: ClipboardHistoryRetentionPeriod
    ) async {
        do {
            switch try await module.prepareRetentionChange(to: period) {
            case .applied(let appliedPeriod):
                retention = appliedPeriod
                retentionConfirmation = nil
                await refreshStorageUsage()
            case .confirmationRequired(let preview):
                retentionConfirmation =
                    ClipboardHistoryRetentionConfirmation(
                        period: period,
                        preview: preview
                    )
            }
            operationFailed = false
        } catch {
            operationFailed = true
        }
    }

    func confirmRetentionChange() async {
        guard let confirmation = retentionConfirmation else { return }
        do {
            switch try await module.confirm(confirmation.preview.token) {
            case .applied:
                retention = confirmation.period
                retentionConfirmation = nil
                await refreshStorageUsage()
            case .stale(let preview):
                retentionConfirmation =
                    ClipboardHistoryRetentionConfirmation(
                        period: confirmation.period,
                        preview: preview
                    )
            }
            operationFailed = false
        } catch {
            operationFailed = true
        }
    }

    func cancelRetentionChange() {
        retentionConfirmation = nil
    }

    func beginClearHistory() async {
        clearIncludesProtected = false
        await refreshClearPreview()
    }

    func setClearIncludesProtected(_ included: Bool) async {
        clearIncludesProtected = included
        await refreshClearPreview()
    }

    func confirmClearHistory() async {
        guard let confirmation = clearConfirmation else { return }
        do {
            switch try await module.confirm(confirmation.preview.token) {
            case .applied:
                clearConfirmation = nil
                await refreshStorageUsage()
            case .stale(let preview):
                clearConfirmation = ClipboardHistoryClearConfirmation(
                    scope: confirmation.scope,
                    preview: preview
                )
            }
            operationFailed = false
        } catch {
            operationFailed = true
        }
    }

    func cancelClearHistory() {
        clearConfirmation = nil
    }

    func addExcludedBundleID(_ bundleID: String) async {
        ClipboardPreferences.addExcludedBundleID(bundleID, to: defaults)
        reloadLocalPreferences()
        await lifecycle.refreshMonitoringConfiguration()
    }

    func removeExcludedBundleID(_ bundleID: String) async {
        ClipboardPreferences.removeExcludedBundleID(bundleID, from: defaults)
        reloadLocalPreferences()
        await lifecycle.refreshMonitoringConfiguration()
    }

    func retryLifecycle() {
        lifecycle.retry()
    }

    func resetStoreConfirmed() {
        lifecycle.resetConfirmed()
    }

    private func refreshClearPreview() async {
        let scope: ClipboardHistoryClearScope =
            clearIncludesProtected ? .includingProtected : .unprotectedOnly
        do {
            let preview = try await module.previewClearHistory(scope: scope)
            clearConfirmation = ClipboardHistoryClearConfirmation(
                scope: scope,
                preview: preview
            )
            operationFailed = false
        } catch {
            operationFailed = true
        }
    }

    func refreshStorageUsage() async {
        do {
            storageBytes = try await refreshOperations.storageUsage()
        } catch {
            operationFailed = failureIsReportable
        }
    }

    /// Reading state for presentation is not a user operation. While the store
    /// is anything but ready the lifecycle section already says why, so adding
    /// "an operation failed, your history was not reset" on top only reads as a
    /// second, unexplained error for something the user never asked for.
    private var failureIsReportable: Bool {
        lifecycle.state == .ready
    }

    private func reloadLocalPreferences() {
        monitoringEnabled = ClipboardPreferences.monitoringEnabled(
            from: defaults
        )
        copyOnly = ClipboardPreferences.copyOnly(from: defaults)
        ignoresUniversalClipboard =
            ClipboardPreferences.ignoresUniversalClipboard(from: defaults)
        excludedBundleIDs = ClipboardPreferences.excludedBundleIDs(
            from: defaults
        )
    }
}
