import AppKit
import Foundation

/// Captures a screen region, decodes any QR codes inside it with Vision, copies
/// the payload(s) to the clipboard, and shows a bottom-center toast reporting
/// the outcome.
///
/// The toast text is status only — it never includes the decoded payload, by
/// design.
///
/// Every error is absorbed and mapped to a toast — `run()` never propagates.
actor QRCodeProvider: ActionProvider {
    let itemKey: BuiltinItem = .qrcode

    var permission: PermissionStatus { .notRequired }

    func run() async {
        do {
            guard let image = try await RegionCapture.captureRegion() else {
                return // user cancelled — silent, no toast
            }
            let payloads = try await BarcodeRecognizer.scan(image)
            guard !payloads.isEmpty else {
                await ToastPresenter.shared.show(.failure("未识别到二维码"))
                return
            }
            let text = payloads.joined(separator: "\n")
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            await ClipboardHistoryStore.shared.recordText(kind: .qrcode, text: text)
            await ToastPresenter.shared.show(.success("已复制到剪贴板"))
        } catch {
            await ToastPresenter.shared.show(.failure("识别失败"))
        }
    }
}
