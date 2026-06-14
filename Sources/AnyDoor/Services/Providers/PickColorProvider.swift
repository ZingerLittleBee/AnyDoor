import AppKit
import Foundation

/// Presents the macOS system color-sampling loupe, copies the picked color to
/// the clipboard as an uppercase HEX string, and shows a bottom-center toast
/// reporting the outcome.
///
/// Every error is absorbed and mapped to a toast — `run()` never propagates.
actor PickColorProvider: ActionProvider {
    let itemKey: BuiltinItem = .pickColor

    var permission: PermissionStatus { .notRequired }

    func run() async {
        switch await ColorSampler.sample() {
        case .cancelled:
            return // user cancelled — silent, no toast
        case .conversionFailed:
            let msg = await MainActor.run { L(.toastPickColorFailed) }
            await ToastPresenter.shared.show(.failure(msg))
        case .picked(let hex, let swatch):
            // Copy in the user's preferred output format; history still stores the
            // raw hex (the color bucket is hex-based and renders the swatch).
            let formatted = ColorFormat.current.format(hex: hex) ?? hex
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(formatted, forType: .string)
                // Suppress the watcher so it doesn't re-capture this picked color
                // as a generic text entry. Done in the same synchronous MainActor
                // block as the write to stay race-free against the 0.5s poll.
                ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
            }
            await ClipboardHistoryStore.shared.recordColor(hex: hex)
            let colorMsg = await MainActor.run { L(.toastColorCopied, formatted) }
            await ToastPresenter.shared.show(
                .color(message: colorMsg, swatch: swatch)
            )
        }
    }
}
