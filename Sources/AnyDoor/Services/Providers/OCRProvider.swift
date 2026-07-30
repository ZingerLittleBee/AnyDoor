import AppKit
import Foundation
import PluginInterface

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
            // Self-write so the watcher doesn't re-capture this OCR result as
            // a generic text entry.
            await ClipboardSelfWrites.write(string: text)
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
