import Foundation

/// Clears the current general pasteboard without recording that clear as a
/// clipboard-history event.
actor ClearClipboardProvider: ActionProvider {
    let itemKey: BuiltinItem = .clearClipboard
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        await MainActor.run {
            let changeCount = ClipboardActions.clear()
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: changeCount)
            ToastPresenter.shared.show(.success(L(.toastClipboardCleared)))
        }
    }
}
