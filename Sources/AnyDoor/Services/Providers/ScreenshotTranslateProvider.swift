import AppKit
import Foundation

/// Captures a screen region, recognizes its text with Vision, then opens the
/// translation window prefilled with that text (auto-translating immediately).
///
/// User cancellation is silent; every error is mapped to a toast and `run()`
/// never propagates. `@MainActor` because it drives an NSPanel and toasts.
@MainActor
final class ScreenshotTranslateProvider: ActionProvider {
    let itemKey: BuiltinItem = .screenshotTranslate
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        do {
            guard let image = try await RegionCapture.captureRegion() else {
                return // user cancelled — silent, no toast
            }
            let lines = try await TextRecognizer.recognize(image)
            guard !lines.isEmpty else {
                ToastPresenter.shared.show(.failure(L(.toastOcrNoText)))
                return
            }
            let text = lines.joined(separator: "\n")
            TranslationWindowController.shared.showPrefilled(text)
        } catch OCRError.screenCapturePermissionDenied {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
        } catch {
            ToastPresenter.shared.show(.failure(L(.toastRecognitionFailed)))
        }
    }
}
