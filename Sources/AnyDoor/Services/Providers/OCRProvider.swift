import AppKit
import Foundation

/// Captures a screen region, recognizes its text with Vision, copies the text to
/// the clipboard, and shows a bottom-center toast reporting the outcome.
///
/// Every error is absorbed and mapped to a toast — `run()` never propagates.
actor OCRProvider: ActionProvider {
    let itemKey: BuiltinItem = .ocr

    var permission: PermissionStatus { .notRequired }

    func run() async {
        do {
            guard let image = try await RegionCapture.captureRegion() else {
                return // user cancelled — silent, no toast
            }
            let lines = try await TextRecognizer.recognize(image)
            guard !lines.isEmpty else {
                let msg = await MainActor.run { L(.toastOcrNoText) }
                await ToastPresenter.shared.show(.failure(msg))
                return
            }
            let text = lines.joined(separator: "\n")
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // Suppress the watcher so it doesn't re-capture this OCR result as
                // a generic text entry. Done in the same synchronous MainActor block
                // as the write to stay race-free against the 0.5s poll.
                ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
            }
            await ClipboardHistoryStore.shared.recordText(kind: .ocr, text: text)
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
