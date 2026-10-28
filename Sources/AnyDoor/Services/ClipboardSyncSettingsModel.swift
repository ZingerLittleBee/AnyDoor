import ClipboardHistory
import Foundation
import Observation

@MainActor
@Observable
final class ClipboardSyncSettingsModel {
    private let module: ClipboardHistoryModule
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var actionGeneration = 0

    private(set) var status = ClipboardHistorySyncStatus()
    private(set) var tags: [ClipboardHistorySyncTag] = []
    private(set) var operationFailed = false
    private(set) var isPerformingAction = false
    private(set) var mergePreview: ClipboardHistorySyncTagMergePreview?

    init(module: ClipboardHistoryModule) {
        self.module = module
    }

    var recoveryHelpURL: URL? {
        guard status.isEnabled else { return nil }
        switch status.phase {
        case .waitingForKey, .keyLocked, .accessDenied, .failed(.corruptData), .failed(.recoveryRequired):
            return URL(string: "https://support.apple.com/guide/security/secure-icloud-keychain-recovery-secdeb202947/web")
        default:
            return nil
        }
    }

    var canSelectTag: Bool {
        status.isEnabled && !isPerformingAction
    }

    func setEnabled(_ enabled: Bool) async {
        // Stopping must remain available while an account request or transfer
        // is suspended. The module cancels that work before persisting Off.
        guard !enabled || !isPerformingAction else { return }
        await performAction {
            try await module.setSyncEnabled(enabled)
        }
    }

    func selectTag(_ id: String, selected: Bool = true) async {
        guard canSelectTag, tags.contains(where: { $0.id == id }) else {
            return
        }
        await performAction {
            try await module.setSyncTagSelected(id, selected: selected)
        }
    }

    func prepareMerge(sourceID: String, targetID: String) async {
        guard canSelectTag else { return }
        mergePreview = nil
        await performAction {
            mergePreview = try await module.prepareSyncTagMerge(sourceID: sourceID, targetID: targetID)
        }
    }
    func confirmMerge(_ confirmedPreview: ClipboardHistorySyncTagMergePreview? = nil) async {
        guard let preview = confirmedPreview ?? mergePreview, canSelectTag else { return }
        mergePreview = nil
        await performAction { try await module.mergeSyncTags(preview) }
    }
    func cancelMerge() { mergePreview = nil }

    func tagTitle(_ tag: ClipboardHistorySyncTag) -> String {
        ClipboardTagLabel.title(id: tag.id, name: tag.displayName,
            among: tags.map { .init(id: $0.id, displayName: $0.displayName) })
    }

    func retry() async {
        guard !isPerformingAction else { return }
        await performAction {
            await module.retrySync()
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let currentStatus = await module.syncStatus()
        do {
            let currentTags = try await module.syncTags()
            guard generation == refreshGeneration, !Task.isCancelled else {
                return
            }
            status = currentStatus
            tags = currentTags
            operationFailed = false
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else {
                return
            }
            status = currentStatus
            operationFailed = true
        }
    }

    private func performAction(_ action: () async throws -> Void) async {
        actionGeneration += 1
        let generation = actionGeneration
        isPerformingAction = true
        operationFailed = false
        defer {
            if generation == actionGeneration { isPerformingAction = false }
        }
        do {
            try await action()
            guard generation == actionGeneration else { return }
            await refresh()
        } catch {
            guard generation == actionGeneration else { return }
            await refresh()
            if generation == actionGeneration { operationFailed = true }
        }
    }
}
