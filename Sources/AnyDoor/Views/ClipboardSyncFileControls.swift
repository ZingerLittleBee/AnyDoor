import ClipboardHistory
import SwiftUI

struct ClipboardSyncFileControls: View {
    let entry: ClipboardHistoryEntry
    let presentation: ClipboardHistoryPresentationModel
    @State private var requests: Set<UUID> = []

    private var pending: [ClipboardHistorySyncFileSummary] {
        let conflictIDs = Set(conflicts.map(\.id))
        return entry.syncFiles.filter { file in
            !conflictIDs.contains(file.id) &&
                (file.uploadPending || file.state == .waitingForDownload || file.state == .updateAvailable || file.transferFailure != nil)
        }
    }

    private var conflicts: [ClipboardHistorySyncFileSummary] {
        entry.syncFiles.filter { file in
            file.hasConflict || entry.linkedFileLocations.contains { $0.objectID == file.id && $0.state == .conflict }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pending.isEmpty || !conflicts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(conflicts) { file in
                            HStack {
                                Text(file.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button(L(.clipboardFileConflictTitle)) {
                                    Task { await presentation.beginFileConflict(entryID: entry.id, objectID: file.id) }
                                }
                                .accessibilityLabel(L(.clipboardFileConflictTitle) + ": " + file.displayName)
                            }
                        }
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
                                if let total = file.transferTotalByteCount ?? file.originalByteCount, file.downloadRequested || file.uploadPending {
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
        .sheet(isPresented: Binding(
            get: { presentation.fileConflictEntryID == entry.id },
            set: { if !$0 && presentation.fileConflictEntryID == entry.id { presentation.dismissFileConflict() } }
        )) {
            ClipboardFileConflictSheet(presentation: presentation)
        }
        .onDisappear {
            if presentation.fileConflictEntryID == entry.id { presentation.dismissFileConflict() }
        }
    }

    private func failureText(_ failure: ClipboardHistorySyncFileFailure) -> String {
        L(failure.presentationMessageKey)
    }
}
