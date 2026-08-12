import AppKit
import ClipboardHistory
import Foundation
import PluginInterface

/// Presents the macOS system color-sampling loupe, copies the picked color to
/// the clipboard as an uppercase HEX string, and shows a bottom-center toast
/// reporting the outcome.
///
/// Every error is absorbed and mapped to a toast — `run()` never propagates.
actor PickColorProvider: ActionProvider {
    let itemKey: BuiltinItem = .pickColor
    private let module: ClipboardHistoryModule

    init(module: ClipboardHistoryModule) {
        self.module = module
    }

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
            // Self-write so the watcher doesn't re-capture this picked color
            // as a generic text entry.
            await ClipboardSelfWrites.write(string: formatted)
            do {
                _ = try await module.capture(
                    ClipboardHistoryCaptureRequest(
                        source: .anyDoor,
                        content: .color(hex)
                    )
                )
                NotificationCenter.default.post(
                    name: .clipboardHistoryV2DidMutate,
                    object: nil
                )
            } catch {
                let msg = await MainActor.run { L(.toastPickColorFailed) }
                await ToastPresenter.shared.show(.failure(msg))
                return
            }
            let colorMsg = await MainActor.run { L(.toastColorCopied, formatted) }
            await ToastPresenter.shared.show(
                .color(message: colorMsg, swatch: swatch)
            )
        }
    }
}
