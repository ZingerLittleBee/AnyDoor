import AppKit
import ClipboardHistory
import SwiftUI

struct ClipboardFileConflictSheet: View {
    @Bindable var presentation: ClipboardHistoryPresentationModel
    @State private var choice: ClipboardHistoryFileConflictChoice?

    private var canChoose: Bool {
        guard let plan = presentation.fileConflictPlan, plan.ancestryComplete,
              !presentation.isPerformingFileConflictAction, let choice else { return false }
        return plan.candidates.contains { $0.id == choice && $0.availability == .available }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L(.clipboardFileConflictTitle)).font(.headline)
            if let plan = presentation.fileConflictPlan {
                Text(plan.displayName).font(.title3).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(L(.clipboardFileConflictMessage)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(plan.candidates.enumerated()), id: \.element.id) { index, candidate in
                            candidateRow(candidate, number: index + 1)
                        }
                    }
                }
                .frame(height: 240)
                if !plan.ancestryComplete {
                    Text(L(.clipboardFileConflictAncestry)).foregroundStyle(.secondary)
                }
            }
            if let notice = presentation.fileConflictNotice {
                Text(noticeText(notice)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if presentation.isPerformingFileConflictAction {
                ProgressView().controlSize(.small)
            }
            Divider()
            HStack {
                if presentation.fileConflictNotice != .submitted {
                    Button(L(.clipboardFileConflictRefresh)) {
                        Task { await presentation.refreshFileConflict() }
                    }
                    .disabled(presentation.isPerformingFileConflictAction)
                }
                Spacer()
                Button(L(presentation.fileConflictNotice == .submitted ? .clipboardPreviewClose : .clipboardEditCancel)) {
                    presentation.dismissFileConflict()
                }
                .keyboardShortcut(.cancelAction)
                if presentation.fileConflictNotice != .submitted {
                    Button(L(.clipboardFileConflictUse)) {
                        guard let choice else { return }
                        Task { await presentation.resolveFileConflict(choosing: choice) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canChoose)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: presentation.fileConflictPlan?.id) { _, _ in choice = nil }
    }

    private func candidateRow(_ candidate: ClipboardHistoryFileConflictCandidate, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Button {
                    choice = candidate.id
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: choice == candidate.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(choice == candidate.id ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidateTitle(candidate, number: number)).fontWeight(.medium)
                            if case .localLocation = candidate.id, let url = candidate.localURL {
                                Text(url.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            if let count = candidate.originalByteCount {
                                Text(ByteCountFormatter.string(fromByteCount: count, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(candidate.availability != .available || presentation.isPerformingFileConflictAction)
                .accessibilityAddTraits(choice == candidate.id ? .isSelected : [])
                if candidate.availability == .available, let url = candidate.localURL {
                    Button(L(.commandPaletteActionOpen)) { NSWorkspace.shared.open(url) }
                        .disabled(presentation.isPerformingFileConflictAction)
                        .accessibilityLabel(L(.commandPaletteActionOpen) + ": " + candidateTitle(candidate, number: number))
                }
            }
            HStack {
                Text(availabilityText(candidate.availability)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if candidate.availability == .requiresDownload, case .version(let versionID) = candidate.id {
                    Button(L(.clipboardFileConflictDownload)) {
                        Task { await presentation.downloadFileConflictVersion(versionID) }
                    }
                    .disabled(presentation.isPerformingFileConflictAction)
                }
            }
        }
        .padding(12)
        .background(choice == candidate.id ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8))
    }

    private func candidateTitle(_ candidate: ClipboardHistoryFileConflictCandidate, number: Int) -> String {
        switch candidate.id {
        case .version: L(.clipboardFileConflictSharedVersion, Int64(number))
        case .localLocation: L(.clipboardFileConflictLocalChanges)
        }
    }

    private func availabilityText(_ availability: ClipboardHistoryFileConflictAvailability) -> String {
        switch availability {
        case .available: L(.clipboardFileConflictAvailable)
        case .requiresDownload: L(.clipboardFileConflictRequiresDownload)
        case .unavailable: L(.clipboardFileConflictCandidateUnavailable)
        }
    }

    private func noticeText(_ notice: ClipboardFileConflictNotice) -> String {
        switch notice {
        case .changed: L(.clipboardFileConflictChanged)
        case .unavailable: L(.clipboardFileConflictUnavailable)
        case .resolutionFailed: L(.clipboardFileConflictResolutionFailed)
        case .submitted: L(.clipboardFileConflictSubmitted)
        case .downloadPending: L(.clipboardFileConflictDownloadPending)
        case .downloadFailed: L(.clipboardFileConflictDownloadFailed)
        }
    }
}
