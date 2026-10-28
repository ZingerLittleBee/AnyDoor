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
                !isStoreReady || (model.isPerformingAction && !model.status.isEnabled)
            )

            LocalizedText(.settingsClipboardSyncDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.tags.isEmpty {
                LocalizedText(.settingsClipboardSyncNoTags)
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    selection: Binding(
                        get: { model.selectedTagID ?? "" },
                        set: { id in Task { await model.selectTag(id) } }
                    )
                ) {
                    LocalizedText(.settingsClipboardSyncChooseTag).tag("")
                    ForEach(model.tags) { tag in
                        Text(L(
                            .settingsClipboardSyncTagCount,
                            tag.displayName,
                            tag.eligibleEntryCount
                        ))
                        .tag(tag.id)
                    }
                } label: {
                    LocalizedText(.settingsClipboardSyncTag)
                }
                .pickerStyle(.menu)
                .disabled(!isStoreReady || !model.canSelectTag)

                LocalizedText(.settingsClipboardSyncBackfill)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.selectedTagID != nil {
                    LocalizedText(.settingsClipboardSyncSelectedTagHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            if isStoreReady, model.operationFailed {
                LocalizedText(.settingsClipboardSyncOperationFailed)
                    .foregroundStyle(.red)
            }
        } header: {
            LocalizedText(.settingsClipboardSyncSection)
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
        if model.operationFailed { return true }
        guard model.status.isEnabled else { return false }
        switch model.status.phase {
        case .disabled, .connecting, .transferring, .upToDate:
            return false
        default:
            return true
        }
    }

    private var statusKey: L10n.Key {
        switch model.status.phase {
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
