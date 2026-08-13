import AppKit
import PluginInterface

/// Presents the macOS system color-sampling loupe, copies the picked color to
/// the clipboard as an uppercase HEX string, and shows a bottom-center toast
/// reporting the outcome.
///
/// Every error is absorbed and mapped to a toast — `run()` never propagates.
actor PickColorProvider: ActionProvider {
    let itemKey: BuiltinItem = .pickColor
    private let clipboardProduction: ClipboardProductionAdapter

    init(clipboardProduction: ClipboardProductionAdapter) {
        self.clipboardProduction = clipboardProduction
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
            do {
                _ = try await clipboardProduction.produceColor(
                    hex: hex,
                    pasteboardValue: formatted
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
