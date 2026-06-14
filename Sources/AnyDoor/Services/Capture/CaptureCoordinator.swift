import AppKit
import Foundation

/// Orchestrates a single capture: resolve mode -> (selection / countdown / direct
/// grab) -> output policy (auto-save + auto-copy + history) -> quick-access overlay.
///
/// The capture engine is `LegacyScreenCapture` (synchronous CoreGraphics), **not**
/// ScreenCaptureKit. A successful SCK capture corrupts the main thread's
/// Swift-concurrency executor tracking on macOS 26, after which unrelated
/// main-actor isolation checks (e.g. SwiftUI hover handlers) crash with
/// EXC_BAD_ACCESS — see `LegacyScreenCapture`. To stay clear of that, this whole
/// flow is callback-based and never `await`s a cross-isolation async: the grabs
/// are synchronous, selection completes via a callback, and the self-timer uses a
/// plain `Task.sleep` (which resumes on the main actor).
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let settings: CaptureSettings
    private let selectionOverlay = SelectionOverlayWindow()
    private var lastRegionRequest: CaptureRequest?
    /// The last committed region rect (global AppKit coordinates), pre-filled into
    /// the selection overlay on re-capture so the previous selection can be reused.
    private var lastRegionRect: CGRect = .zero
    private var inFlight = false
    /// Set for the next capture only, to reuse the previous selection rect.
    private var reuseLastRect = false

    init(settings: CaptureSettings = .shared) {
        self.settings = settings
    }

    /// Entry point used by every provider. Guards against re-entrancy.
    func capture(_ request: CaptureRequest) {
        guard !inFlight else { return }
        guard ScreenCapturePermission.ensureGranted() else {
            // The toast is non-interactive, so deep-link straight to the
            // Screen Recording settings pane where the user can grant access.
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            ScreenCapturePermission.openSettings()
            return
        }
        inFlight = true
        lastRegionRequest = request
        switch request.mode {
        case .region:     captureRegion(delay: request.delay)
        case .window:     captureWindow(delay: request.delay)
        case .fullscreen: captureFullscreen(delay: request.delay)
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

    // MARK: - Capture flows (all on the main actor, callback-based)

    private func captureRegion(delay: Int) {
        guard let target = Self.resolveTargetUnderMouse(),
              let frozen = LegacyScreenCapture.display(target.id) else { finish(); return }
        let initialRect = reuseLastRect ? lastRegionRect : .zero
        reuseLastRect = false
        selectionOverlay.present(target: target, mode: .region, frozen: frozen, initialRect: initialRect) { [weak self] result in
            guard let self else { return }
            guard case let .region(cgImage, rect) = result else { self.finish(); return }
            self.lastRegionRect = rect
            self.afterCountdown(delay) { [weak self] in
                self?.present(image: cgImage, anchor: rect)
                self?.finish()
            }
        }
    }

    private func captureWindow(delay: Int) {
        guard let target = Self.resolveTargetUnderMouse(),
              let frozen = LegacyScreenCapture.display(target.id) else { finish(); return }
        selectionOverlay.present(target: target, mode: .window, frozen: frozen) { [weak self] result in
            guard let self else { return }
            guard case let .window(id, frame) = result else { self.finish(); return }
            self.afterCountdown(delay) { [weak self] in
                guard let self else { return }
                guard let cg = LegacyScreenCapture.window(id) else {
                    ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                    self.finish(); return
                }
                self.present(image: cg, anchor: frame)
                self.finish()
            }
        }
    }

    private func captureFullscreen(delay: Int) {
        afterCountdown(delay) { [weak self] in
            guard let self else { return }
            guard let target = Self.resolveTargetUnderMouse(),
                  let cg = LegacyScreenCapture.display(target.id) else {
                ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                self.finish(); return
            }
            self.present(image: cg, anchor: nil)
            self.finish()
        }
    }

    /// Run `body` on the main actor after `seconds`. Uses `Task.sleep` (which
    /// resumes on the main actor) — no cross-isolation await, so it is safe with
    /// respect to the executor-tracking bug described in `LegacyScreenCapture`.
    private func afterCountdown(_ seconds: Int, _ body: @escaping @MainActor () -> Void) {
        guard seconds > 0 else { body(); return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            body()
        }
    }

    private func finish() { inFlight = false }

    @MainActor private static func resolveTargetUnderMouse() -> TargetDisplay? {
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main
        guard let screen, let id = screen.displayID else { return nil }
        return TargetDisplay(id: id, frame: screen.frame, backingScale: screen.backingScaleFactor)
    }

    // MARK: - Output

    /// Apply output policy and show the quick-access overlay. Synchronous —
    /// history recording is fire-and-forget so this never awaits.
    private func present(image cg: CGImage, anchor: CGRect?) {
        let image = NSImage(cgImage: cg, size: .zero)
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
        // Shared box so the delete action can remove the exact history entry once
        // the async record completes (both hops run on the main actor — no race).
        let recordedID = HistoryIDBox()
        Task { recordedID.value = await ClipboardHistoryStore.shared.recordScreenshot(pngData: png) }

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
            delete: {
                savedURL.map { try? FileManager.default.removeItem(at: $0) }
                if let id = recordedID.value {
                    Task { await ClipboardHistoryStore.shared.deleteScreenshot(id: id) }
                }
                ToastPresenter.shared.show(.success(L(.captureToastDeleted)))
            }
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
        // Run Vision off the main actor and hop back only with the result.
        Task.detached {
            do {
                let lines = try await TextRecognizer.recognize(cg)
                let text = lines.joined(separator: "\n")
                await MainActor.run {
                    guard !text.isEmpty else {
                        ToastPresenter.shared.show(.failure(L(.toastOcrNoText)))
                        return
                    }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    ClipboardWatcher.shared?.noteSelfWrite(changeCount: pb.changeCount)
                    Task { await ClipboardHistoryStore.shared.recordText(kind: .ocr, text: text) }
                    ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
                }
            } catch {
                await MainActor.run { ToastPresenter.shared.show(.failure(L(.toastRecognitionFailed))) }
            }
        }
    }

    private func recapture() {
        // Reuse the previous region rect when re-capturing a region.
        let request = lastRegionRequest ?? CaptureRequest(mode: .region)
        if request.mode == .region, !lastRegionRect.isEmpty { reuseLastRect = true }
        capture(request)
    }
}

/// Mutable holder for the recorded history id, shared between the async record
/// task and the overlay's delete action. Main-actor confined, so the two hops
/// never race.
@MainActor private final class HistoryIDBox {
    var value: UUID?
}

/// PNG encoding for an NSImage via its CGImage.
extension NSImage {
    func pngData() -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
