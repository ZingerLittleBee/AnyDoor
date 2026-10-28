import ClipboardHistory
import SwiftUI

struct ClipboardApplicationUpdateSheet: View {
    @Bindable var presentation: ClipboardHistoryPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L(.clipboardApplicationUpdateTitle)).font(.headline)
            if let plan = presentation.applicationUpdatePlan {
                Text(plan.displayName).font(.title3).lineLimit(2).truncationMode(.middle)
                Text(plan.locationURL.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                Text(L(plan.state.applicationUpdateMessageKey))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = presentation.applicationUpdateNotice {
                Text(L(notice.messageKey)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if presentation.isPerformingApplicationUpdateAction {
                ProgressView().controlSize(.small)
            }
            Divider()
            HStack {
                if presentation.applicationUpdateNotice != .applied {
                    Button(L(.clipboardFileConflictRefresh)) {
                        Task { await presentation.refreshApplicationUpdate() }
                    }
                    .disabled(presentation.isPerformingApplicationUpdateAction)
                }
                Spacer()
                Button(L(.clipboardPreviewClose)) { presentation.dismissApplicationUpdate() }
                    .keyboardShortcut(.cancelAction)
                if presentation.applicationUpdatePlan?.state == .requiresDownload {
                    Button(L(.clipboardApplicationUpdateDownload)) {
                        Task { await presentation.downloadApplicationUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(presentation.isPerformingApplicationUpdateAction)
                } else if presentation.applicationUpdatePlan != nil {
                    Button(L(.clipboardApplicationUpdateTitle)) {
                        Task { await presentation.applyApplicationUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(presentation.isPerformingApplicationUpdateAction || presentation.applicationUpdatePlan?.state != .ready)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

extension ClipboardHistoryApplicationUpdateState {
    var applicationUpdateMessageKey: L10n.Key {
        switch self {
        case .ready: .clipboardApplicationUpdateReady
        case .requiresDownload: .clipboardApplicationUpdateRequiresDownload
        case .running: .clipboardApplicationUpdateRunning
        case .identityUncertain: .clipboardApplicationUpdateIdentityUncertain
        case .localChanges: .clipboardApplicationUpdateLocalChanges
        case .conflict: .clipboardApplicationUpdateConflict
        case .unavailable: .clipboardApplicationUpdateUnavailable
        }
    }
}

extension ClipboardApplicationUpdateNotice {
    var messageKey: L10n.Key {
        switch self {
        case .applied: .clipboardApplicationUpdateApplied
        case .changed: .clipboardApplicationUpdateChanged
        case .unavailable: .clipboardApplicationUpdateUnavailable
        case .applyFailed: .clipboardApplicationUpdateFailed
        case .downloadPending: .clipboardApplicationUpdateDownloadPending
        case .downloadFailed: .clipboardApplicationUpdateDownloadFailed
        case .blocked(let state): state.applicationUpdateMessageKey
        }
    }
}
