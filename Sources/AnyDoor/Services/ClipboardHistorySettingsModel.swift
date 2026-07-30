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

@MainActor
@Observable
final class ClipboardHistorySettingsModel {
    private let module: ClipboardHistoryModule
    let lifecycle: ClipboardHistoryLifecycle
    private let defaults: UserDefaults
    @ObservationIgnored private var latestSettingsAppearanceGeneration:
        UInt64 = 0

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
        defaults: UserDefaults = .standard
    ) {
        self.module = module
        self.lifecycle = lifecycle
        self.defaults = defaults
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

    /// Refreshes the settings-derived state for one visible Settings
    /// presentation. A reused Settings host can request a newer generation
    /// while a previous read is suspended; only the newest result may update
    /// this UI model.
    func refreshForSettingsAppearance(_ generation: UInt64) async {
        guard generation > latestSettingsAppearanceGeneration else { return }
        latestSettingsAppearanceGeneration = generation
        await refresh(expectedSettingsAppearanceGeneration: generation)
    }

    private func refresh(
        expectedSettingsAppearanceGeneration: UInt64?
    ) async {
        do {
            guard shouldApplyRefresh(
                expectedSettingsAppearanceGeneration
            ) else { return }
            let retention = try await module.retentionStatus().period
            guard shouldApplyRefresh(
                expectedSettingsAppearanceGeneration
            ) else { return }
            let automaticImageTextIndexingEnabled =
                try await module.isAutomaticImageTextIndexingEnabled()
            guard shouldApplyRefresh(
                expectedSettingsAppearanceGeneration
            ) else { return }
            let storageBytes = try await module.storageUsage()
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
            operationFailed = true
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
                await module.advanceMonitoringBaseline()
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
            storageBytes = try await module.storageUsage()
        } catch {
            operationFailed = true
        }
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
