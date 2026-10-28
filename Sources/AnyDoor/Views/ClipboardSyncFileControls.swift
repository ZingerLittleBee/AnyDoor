import ClipboardHistory
import SwiftUI

struct ClipboardSyncFileControls: View {
    let entry: ClipboardHistoryEntry
    let presentation: ClipboardHistoryPresentationModel
    @State private var requests: Set<UUID> = []

    private var pending: [ClipboardHistorySyncFileSummary] {
        entry.syncFiles.filter { $0.uploadPending || $0.state == .waitingForDownload || $0.state == .updateAvailable || $0.transferFailure != nil }
    }

    var body: some View {
        if !pending.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pending) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(file.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button(L(file.transferFailure == nil && !file.downloadRequested && !file.uploadPending
                                    ? .clipboardSyncFileDownload : .settingsClipboardSyncRetry)) {
                                    requests.insert(file.versionID)
                                    Task {
                                        await presentation.transferSyncFile(file, entryID: entry.id)
                                        requests.remove(file.versionID)
                                    }
                                }
                                .disabled(requests.contains(file.versionID))
                                .accessibilityLabel(L(.clipboardSyncFileDownload) + ": " + file.displayName)
                            }
                            if let total = file.originalByteCount, file.downloadRequested || file.uploadPending {
                                ProgressView(value: Double(min(total, file.transferredByteCount)), total: Double(max(1, total)))
                                    .accessibilityLabel(file.displayName)
                                Text(L(.clipboardSyncFileProgress,
                                    ByteCountFormatter.string(fromByteCount: file.transferredByteCount, countStyle: .file),
                                    ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                                    .foregroundStyle(.secondary)
                            }
                            if let failure = file.transferFailure {
                                Text(failureText(failure)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 72)
            .font(.caption)
            .controlSize(.small)
        }
    }

    private func failureText(_ failure: ClipboardHistorySyncFileFailure) -> String {
        let key: L10n.Key = switch failure {
        case .network: .settingsClipboardSyncNetworkFailure
        case .quota: .settingsClipboardSyncQuotaFailure
        case .localStorage: .settingsClipboardSyncStorageFailure
        case .corruptData: .settingsClipboardSyncCorruptData
        case .accessDenied: .settingsClipboardSyncAccessDenied
        case .accountChanged: .settingsClipboardSyncAccountChanged
        case .keyUnavailable: .settingsClipboardSyncWaitingForKey
        case .unavailable: .settingsClipboardSyncCapabilityUnavailable
        }
        return L(key)
    }
}
