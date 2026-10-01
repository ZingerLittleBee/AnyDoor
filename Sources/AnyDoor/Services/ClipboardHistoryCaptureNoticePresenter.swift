import ClipboardHistory

/// Shows passive capture notices from the Clipboard History module. The module
/// already rate limits them; the lines are static, so a toast never echoes
/// what was refused.
@MainActor
enum ClipboardHistoryCaptureNoticePresenter {
    static func present(
        _ notice: ClipboardHistoryCaptureNotice,
        show: (ToastStyle) -> Void = { ToastPresenter.shared.show($0) }
    ) {
        let key: L10n.Key = switch notice {
        case .tooLarge: .clipboardToastCaptureTooLarge
        case .captureFailed: .clipboardToastCaptureFailed
        }
        show(.failure(L(key)))
    }
}
