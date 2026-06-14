import AppKit
import Foundation

/// Orchestrates a single capture: resolve mode -> (selection / countdown / direct
/// grab) -> output policy (auto-save + auto-copy + history) -> quick-access overlay.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let settings: CaptureSettings
    private let selectionOverlay = SelectionOverlayWindow()
    private var lastRegionRequest: CaptureRequest?
    private var inFlight = false

    init(settings: CaptureSettings = .shared) {
        self.settings = settings
    }

    /// Entry point used by every provider. Guards against re-entrancy.
    func capture(_ request: CaptureRequest) {
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            await self?.run(request)
            self?.inFlight = false
        }
    }

    /// Opens the All-In-One mode bar; the chosen mode starts a capture.
    func presentModeBar() {
        CaptureModeBarWindow.shared.present(
            onPick: { [weak self] mode in self?.capture(CaptureRequest(mode: mode)) },
            onTimer: { [weak self] in
                guard let self else { return }
                self.capture(CaptureRequest(mode: .region, delay: self.settings.delaySeconds))
            }
        )
    }

    private func run(_ request: CaptureRequest) async {
        guard ScreenCapturePermission.isGranted || ScreenCapturePermission.request() else {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            return
        }
        let captured: (image: NSImage, anchor: CGRect?)?
        switch request.mode {
        case .region:     captured = await captureRegion(delay: request.delay)
        case .window:     captured = await captureWindow(delay: request.delay)
        case .fullscreen: captured = await captureFullscreen(delay: request.delay)
        }
        guard let captured else { return }
        lastRegionRequest = request
        await present(image: captured.image, anchor: captured.anchor)
    }

    private func captureRegion(delay: Int) async -> (NSImage, CGRect?)? {
        let result = await withSelection(mode: .region)
        guard case let .region(cgImage, rect) = result else { return nil }
        await countdown(delay)
        return (NSImage(cgImage: cgImage, size: .zero), rect)
    }

    private func captureWindow(delay: Int) async -> (NSImage, CGRect?)? {
        let result = await withSelection(mode: .window)
        guard case let .window(id, frame) = result else { return nil }
        await countdown(delay)
        do {
            let cg = try await ScreenCaptureService.shared.captureWindow(id)
            return (NSImage(cgImage: cg, size: .zero), frame)
        } catch {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return nil
        }
    }

    private func captureFullscreen(delay: Int) async -> (NSImage, CGRect?)? {
        await countdown(delay)
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main
        guard let displayID = screen?.displayID else { return nil }
        do {
            let cg = try await ScreenCaptureService.shared.captureDisplay(displayID)
            return (NSImage(cgImage: cg, size: .zero), nil)
        } catch {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return nil
        }
    }

    private func withSelection(mode: CaptureMode) async -> SelectionResult {
        await withCheckedContinuation { continuation in
            Task {
                await selectionOverlay.present(mode: mode) { result in
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func countdown(_ seconds: Int) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func present(image: NSImage, anchor: CGRect?) async {
        guard let png = image.pngData() else {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return
        }
        var savedURL: URL?
        if settings.autoSave { savedURL = saveToDefaultDirectory(png: png) }
        if settings.autoCopy {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: pb.changeCount)
        }
        await ClipboardHistoryStore.shared.recordScreenshot(pngData: png)

        let actions = CaptureOverlayActions(
            copy: { [weak self] in self?.copyToPasteboard(image) },
            save: { [weak self] in self?.saveInteractive(png: png, existing: savedURL) },
            edit: { AnnotationEditorWindow.shared.show(image: image) },
            pin: {
                let screen = NSScreen.screenUnderMouse ?? NSScreen.main
                PinnedImageWindow.show(image: image, at: screen?.frame ?? .zero)
            },
            ocr: { [weak self] in self?.runOCR(image) },
            recapture: { [weak self] in self?.recapture() },
            delete: { savedURL.map { try? FileManager.default.removeItem(at: $0) } }
        )
        CaptureOverlayWindow.shared.present(
            image: image, fileURL: savedURL, anchor: anchor,
            timeout: settings.overlayTimeout, actions: actions
        )
    }

    private func saveToDefaultDirectory(png: Data) -> URL? {
        let dir = settings.saveDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = CaptureFilename.make(template: settings.namingTemplate, date: Date(), calendar: .current)
            let name = CaptureFilename.resolve(base: base, ext: "png") {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            let url = dir.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            ToastPresenter.shared.show(.success(L(.captureToastSaved, dir.lastPathComponent)))
            return url
        } catch {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return nil
        }
    }

    private func saveInteractive(png: Data, existing: URL?) {
        if let existing {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CaptureFilename.make(template: settings.namingTemplate, date: Date(), calendar: .current) + ".png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url, options: .atomic)
        }
    }

    private func copyToPasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pb.changeCount)
        ToastPresenter.shared.show(.success(L(.captureToastCopied)))
    }

    private func runOCR(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Task {
            do {
                let lines = try await TextRecognizer.recognize(cg)
                let text = lines.joined(separator: "\n")
                guard !text.isEmpty else {
                    ToastPresenter.shared.show(.failure(L(.toastOcrNoText)))
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                ClipboardWatcher.shared?.noteSelfWrite(changeCount: pb.changeCount)
                await ClipboardHistoryStore.shared.recordText(kind: .ocr, text: text)
                ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
            } catch {
                ToastPresenter.shared.show(.failure(L(.toastRecognitionFailed)))
            }
        }
    }

    private func recapture() {
        if let last = lastRegionRequest { capture(last) }
        else { capture(CaptureRequest(mode: .region)) }
    }
}

/// PNG encoding for an NSImage via its CGImage.
extension NSImage {
    func pngData() -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
