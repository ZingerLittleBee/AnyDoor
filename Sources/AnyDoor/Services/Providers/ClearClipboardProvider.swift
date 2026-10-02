import AppKit
import Foundation
import PluginInterface

/// Clears the current general pasteboard without recording that clear as a
/// clipboard-history event.
actor ClearClipboardProvider: ActionProvider {
    let itemKey: BuiltinItem = .clearClipboard
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        await MainActor.run {
            ClipboardSelfWrites.perform { $0.clearContents() }
            ToastPresenter.shared.show(.success(L(.toastClipboardCleared)))
        }
    }
}
