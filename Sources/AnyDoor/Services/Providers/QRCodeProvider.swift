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
                let msg = await MainActor.run { L(.toastQrcodeNoCode) }
                await ToastPresenter.shared.show(.failure(msg))
                return
            }
            let text = payloads.joined(separator: "\n")
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // Suppress the watcher so it doesn't re-capture this QR payload as
                // a generic text entry. Done in the same synchronous MainActor block
                // as the write to stay race-free against the 0.5s poll.
                ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
            }
            await ClipboardHistoryStore.shared.recordText(kind: .qrcode, text: text)
            let successMsg = await MainActor.run { L(.toastCopiedToClipboard) }
            await ToastPresenter.shared.show(.success(successMsg))
        } catch OCRError.screenCapturePermissionDenied {
            let errMsg = await MainActor.run { L(.toastScreenCapturePermissionDenied) }
            await ToastPresenter.shared.show(.failure(errMsg))
        } catch {
            let errMsg = await MainActor.run { L(.toastRecognitionFailed) }
            await ToastPresenter.shared.show(.failure(errMsg))
        }
    }
}
