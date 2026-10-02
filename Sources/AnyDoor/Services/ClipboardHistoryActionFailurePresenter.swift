import Foundation

struct ClipboardHistoryActionFailureNotice: Equatable {
    enum Detail: Equatable {
        case legacyOwned(count: Int)
        case unavailable(count: Int)
    }

    let titleKey: L10n.Key
    let details: [Detail]

    init(_ failure: ClipboardHistoryActionFailure) {
        switch failure {
        case .fileReferencesUnavailable(_, let count):
            titleKey = .clipboardToastFileMissing
            details = [.unavailable(count: count)]
        case .payloadUnavailable:
            // A migrated entry whose owned copy was already gone, or a payload
            // lost since. "Copy failed" alone leaves the user retrying an
            // entry that can never paste.
            titleKey = .clipboardToastPayloadUnavailable
            details = []
        case .fileCollectionRequiresRestore(
            _,
            let ownedCount,
            let unavailableCount
        ):
            titleKey = .clipboardToastCopyFailed
            // Either count can be zero, and a detail of zero files explains
            // nothing.
            var restoreDetails: [Detail] = []
            if ownedCount > 0 {
                restoreDetails.append(.legacyOwned(count: ownedCount))
            }
            if unavailableCount > 0 {
                restoreDetails.append(.unavailable(count: unavailableCount))
            }
            details = restoreDetails
        default:
            titleKey = .clipboardToastCopyFailed
            details = []
        }
    }

    @MainActor
    var message: String {
        let detailMessages = details.map { detail in
            switch detail {
            case .legacyOwned(let count):
                L(.clipboardToastLegacyOwnedCount, count)
            case .unavailable(let count):
                L(.clipboardToastUnavailableCount, count)
            }
        }
        return ([L(titleKey)] + detailMessages).joined(separator: " · ")
    }
}

@MainActor
enum ClipboardHistoryActionFailurePresenter {
    static func present(_ failure: ClipboardHistoryActionFailure?) {
        let notice = ClipboardHistoryActionFailureNotice(
            failure ?? .unknown
        )
        ToastPresenter.shared.show(.failure(notice.message))
    }

    /// A successful copy shows nothing here; the caller gives its own feedback.
    /// Neither does a discarded one, which nobody wants anymore.
    static func present(_ outcome: ClipboardHistoryCopyOutcome) {
        guard let message = failureMessage(for: outcome) else { return }
        ToastPresenter.shared.show(.failure(message))
    }

    /// What a copy that ended with `outcome` reports, or nil when it reports
    /// nothing.
    static func failureMessage(
        for outcome: ClipboardHistoryCopyOutcome
    ) -> String? {
        switch outcome {
        case .copied, .discarded:
            nil
        case .materializationFailed(let failure):
            ClipboardHistoryActionFailureNotice(failure ?? .unknown).message
        case .plainTextUnavailable:
            // Not "Copy failed": nothing is wrong with the entry, it just
            // has no plain text to paste.
            L(.clipboardToastPlainTextUnavailable)
        case .pasteboardWriteFailed:
            ClipboardHistoryActionFailureNotice(.unknown).message
        }
    }
}
