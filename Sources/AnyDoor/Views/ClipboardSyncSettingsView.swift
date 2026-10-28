import ClipboardHistory
import SwiftUI

@MainActor
struct ClipboardSyncSettingsView: View {
    @State private var model: ClipboardSyncSettingsModel
    let isStoreReady: Bool

    init(module: ClipboardHistoryModule, isStoreReady: Bool) {
        _model = State(initialValue: ClipboardSyncSettingsModel(module: module))
        self.isStoreReady = isStoreReady
    }

    var body: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { model.status.isEnabled },
                    set: { enabled in Task { await model.setEnabled(enabled) } }
                )
            ) {
                LocalizedText(.settingsClipboardSyncEnable)
            }
            .disabled(
                !isStoreReady || model.isResetPending || (model.isPerformingAction && !model.status.isEnabled)
            )

            LocalizedText(.settingsClipboardSyncDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.tags.isEmpty {
                LocalizedText(.settingsClipboardSyncNoTags)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.tags) { tag in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { tag.isSelected },
                            set: { selected in Task { await model.selectTag(tag.id, selected: selected) } }
                        )) {
                            Text(L(.settingsClipboardSyncTagCount, model.tagTitle(tag), tag.eligibleEntryCount))
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!isStoreReady || !model.canSelectTag)
                        Spacer()
                        let candidates = model.tags.filter {
                            $0.id != tag.id && $0.displayName == tag.displayName && ($0.isSelected || tag.isSelected)
                        }
                        if !candidates.isEmpty {
                            Menu {
                                ForEach(candidates) { target in
                                    Button(L(.settingsClipboardSyncMergeWith, model.tagTitle(target))) {
                                        Task { await model.prepareMerge(sourceID: tag.id, targetID: target.id) }
                                    }
                                }
                            } label: {
                                LocalizedText(.settingsClipboardSyncMergeTitle)
                            }
                            .fixedSize()
                            .disabled(!isStoreReady || !model.canSelectTag)
                        }
                    }
                    if tag.isSelected && tag.withdrawalEntryCount > 0 {
                        Text(L(.settingsClipboardSyncWithdrawalScope, tag.withdrawalEntryCount))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if tag.rejoinEntryCount > 0 {
                        Text(L(.settingsClipboardSyncRejoinScope, tag.rejoinEntryCount))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if tag.isSelected && tag.rejoinEntryCount > 0 {
                        Button(L(.settingsClipboardSyncRejoinAction)) {
                            Task { await model.selectTag(tag.id) }
                        }
                        .disabled(!isStoreReady || !model.canSelectTag)
                    }
                    if tag.requiresLocalAuthorization {
                        Button(L(.settingsClipboardSyncAuthorizeRetained, model.tagTitle(tag))) {
                            Task { await model.selectTag(tag.id) }
                        }
                        .disabled(!isStoreReady || !model.canSelectTag)
                    }
                }

                LocalizedText(.settingsClipboardSyncBackfill)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LocalizedText(.settingsClipboardSyncSharingScope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top) {
                if isTransferring {
                    ProgressView().controlSize(.small)
                }
                LocalizedText(statusKey)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if offersRetry {
                    Button {
                        Task { await model.retry() }
                    } label: {
                        LocalizedText(.settingsClipboardSyncRetry)
                    }
                    .disabled(!isStoreReady || model.isPerformingAction)
                }
            }

            if model.status.withdrawnEntryCount > 0 {
                Text(L(.settingsClipboardSyncWithdrawnStatus, model.status.withdrawnEntryCount))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !model.preservedEdits.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L(.settingsClipboardSyncPreserved, model.preservedEdits.count))
                    ForEach(model.preservedEdits) { entry in
                        Text(entry.previewText).lineLimit(2).font(.caption)
                    }
                    Button(L(.settingsClipboardSyncPreservedDismiss)) {
                        Task { await model.dismissPreservedEdits() }
                    }
                    .disabled(model.isPerformingAction)
                }
            }

            if let recoveryURL = model.recoveryHelpURL {
                Link(destination: recoveryURL) {
                    LocalizedText(.settingsClipboardSyncRecoveryHelp)
                }
                .font(.caption)
            }

            if model.status.uploadedEntryCount > 0
                || model.status.receivedEntryCount > 0
            {
                Text(L(
                    .settingsClipboardSyncCounts,
                    model.status.uploadedEntryCount,
                    model.status.receivedEntryCount
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let date = model.status.lastCompletedAt {
                LabeledContent {
                    Text(date, format: .dateTime.month().day().hour().minute())
                } label: {
                    LocalizedText(.settingsClipboardSyncLastCompleted)
                }
            }

            if let reset = model.status.cloudReset {
                HStack {
                    if reset.isPending, reset.failure == nil {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading) {
                        LocalizedText(reset.stage == .superseded ? .settingsClipboardSyncResetSuperseded :
                            reset.stage == .completed ? .settingsClipboardSyncResetCompleted :
                            (reset.stage == .preparing ? .settingsClipboardSyncResetPreparing : .settingsClipboardSyncResetClearing))
                        if reset.deletedRecordCount > 0 {
                            Text(L(.settingsClipboardSyncResetProgress, reset.deletedRecordCount))
                        }
                        if reset.failure != nil {
                            LocalizedText(.settingsClipboardSyncResetInterrupted)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                Task { await model.prepareReset() }
            } label: {
                LocalizedText(.settingsClipboardSyncResetAction)
            }
            .disabled(!isStoreReady || !model.status.canClearCloudData || model.isPerformingAction || model.isResetPending)

            if isStoreReady, model.operationFailed {
                LocalizedText(.settingsClipboardSyncOperationFailed)
                    .foregroundStyle(.red)
            }
        } header: {
            LocalizedText(.settingsClipboardSyncSection)
        }
        .confirmationDialog(L(.settingsClipboardSyncResetAction), isPresented: Binding(
            get: { model.resetConfirmation != nil },
            set: { if !$0 { model.cancelResetConfirmation() } }
        ), titleVisibility: .visible) {
            Button(role: .destructive) {
                guard let confirmation = model.resetConfirmation else { return }
                Task { await model.confirmReset(confirmation) }
            } label: {
                LocalizedText(.settingsClipboardSyncResetAction)
            }
        } message: {
            LocalizedText(.settingsClipboardSyncResetExplanation)
        }
        .task(id: isStoreReady) {
            await model.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .clipboardHistorySyncDidChange)
        ) { _ in
            Task { await model.refresh() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .clipboardHistoryV2DidMutate)
        ) { _ in
            Task { await model.refresh() }
        }
        .alert(L(.settingsClipboardSyncMergeTitle), isPresented: Binding(
            get: { model.mergePreview != nil }, set: { if !$0 { model.cancelMerge() } }
        ), presenting: model.mergePreview) { preview in
            Button(L(.settingsClipboardSyncMergeConfirm)) { Task { await model.confirmMerge(preview) } }
            Button(L(.clipboardEditCancel), role: .cancel) { model.cancelMerge() }
        } message: { preview in
            Text(L(.settingsClipboardSyncMergeScope, preview.displayName, preview.newlyEligibleEntryCount))
        }
    }

    private var isTransferring: Bool {
        switch model.status.phase {
        case .connecting, .transferring:
            true
        default:
            false
        }
    }

    private var offersRetry: Bool {
        if model.operationFailed || model.status.cloudReset?.failure != nil { return true }
        guard model.status.isEnabled else { return false }
        switch model.status.phase {
        case .disabled, .connecting, .transferring, .upToDate:
            return false
        default:
            return true
        }
    }

    private var statusKey: L10n.Key {
        switch model.status.cloudReset?.failure ?? model.status.phase {
        case .disabled: .settingsClipboardSyncDisabled
        case .connecting: .settingsClipboardSyncConnecting
        case .waitingForAccount: .settingsClipboardSyncWaitingForAccount
        case .waitingForKey: .settingsClipboardSyncWaitingForKey
        case .keyLocked: .settingsClipboardSyncKeyLocked
        case .accessDenied: .settingsClipboardSyncAccessDenied
        case .capabilityUnavailable: .settingsClipboardSyncCapabilityUnavailable
        case .transferring: .settingsClipboardSyncTransferring
        case .upToDate: .settingsClipboardSyncUpToDate
        case .failed(let failure):
            switch failure {
            case .network: .settingsClipboardSyncNetworkFailure
            case .quota: .settingsClipboardSyncQuotaFailure
            case .localStorage: .settingsClipboardSyncStorageFailure
            case .corruptData: .settingsClipboardSyncCorruptData
            case .recoveryRequired: .settingsClipboardSyncRecoveryRequired
            case .accountChanged: .settingsClipboardSyncAccountChanged
            case .unsupportedVersion: .settingsClipboardSyncUnsupportedVersion
            }
        }
    }
}
