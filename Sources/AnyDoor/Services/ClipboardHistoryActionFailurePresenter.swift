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
        case .fileCollectionRequiresRestore(
            _,
            let ownedCount,
            let unavailableCount
        ):
            titleKey = .clipboardToastCopyFailed
            details = [
                .legacyOwned(count: ownedCount),
                .unavailable(count: unavailableCount),
            ]
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
}
