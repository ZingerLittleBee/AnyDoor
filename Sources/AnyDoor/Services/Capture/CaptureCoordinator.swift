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
    private var inFlight = false

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

    /// Delivers an externally produced capture (e.g. a stitched scrolling
    /// capture) through the standard output policy: auto-save / auto-copy /
    /// history / quick-access overlay.
    func deliverCapturedImage(_ image: CGImage, anchor: CGRect?) {
        present(image: image, anchor: anchor)
    }

    // MARK: - Capture flows (all on the main actor, callback-based)

    private func captureRegion(delay: Int) {
        let (targets, frozen) = Self.resolveAllDisplays()
        guard !targets.isEmpty else { finish(); return }
        let initialRect = Self.initialSelectionRect(targets: targets, settings: settings)
        selectionOverlay.present(targets: targets, mode: .region, frozen: frozen, initialRect: initialRect) { [weak self] result in
            self?.handle(result, delay: delay)
        }
    }

    /// The pre-shown selection rect (global AppKit coords): the persisted last
    /// rect when its center lies on a connected display, else a default rect
    /// centered on the display under the cursor (or the first display).
    @MainActor private static func initialSelectionRect(targets: [TargetDisplay], settings: CaptureSettings) -> CGRect {
        let displays = targets.map(\.frame)
        if let restored = SelectionGeometry.restoredRect(last: settings.lastRegionRect, displays: displays) {
            // Clamp to the display holding its center so a rect saved at a larger
            // resolution cannot pre-show off-screen edges after a display change.
            let center = CGPoint(x: restored.midX, y: restored.midY)
            let display = displays.first(where: { $0.contains(center) }) ?? displays[0]
            return SelectionGeometry.clamped(restored, to: display)
        }
        let mouse = NSEvent.mouseLocation
        let screen = targets.first(where: { $0.frame.contains(mouse) })?.frame ?? targets[0].frame
        return SelectionGeometry.defaultCenteredRect(in: screen, fraction: 0.5)
    }

    private func captureWindow(delay: Int) {
        let (targets, frozen) = Self.resolveAllDisplays()
        guard !targets.isEmpty else { finish(); return }
        selectionOverlay.present(targets: targets, mode: .window, frozen: frozen) { [weak self] result in
            self?.handle(result, delay: delay)
        }
    }

    /// Routes a selection overlay result through the output policy. Shared by the
    /// unified region overlay (which can return region/window/fullscreen via the
    /// toolbar) and the standalone window overlay.
    private func handle(_ result: SelectionResult, delay: Int) {
        switch result {
        case let .region(cgImage, rect):
            settings.setLastRegionRect(rect)
            afterCountdown(delay) { [weak self] in
                self?.present(image: cgImage, anchor: rect)
                self?.finish()
            }
        case let .window(id, frame):
            afterCountdown(delay) { [weak self] in
                guard let self else { return }
                guard let cg = LegacyScreenCapture.window(id) else {
                    ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                    self.finish(); return
                }
                self.present(image: cg, anchor: frame)
                self.finish()
            }
        case let .fullscreen(cgImage, _):
            afterCountdown(delay) { [weak self] in
                self?.present(image: cgImage, anchor: nil)
                self?.finish()
            }
        case let .scrolling(rect):
            finish()
            ScrollCaptureCoordinator.shared.capture(region: rect)
        case let .recording(rect):
            finish()
            RecordingCoordinator.shared.record(rect: rect)
        case .cancelled:
            finish()
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

    /// Every connected display plus its frozen still, for the all-screens
    /// selection overlay. Displays whose grab fails are dropped.
    @MainActor private static func resolveAllDisplays() -> ([TargetDisplay], [CGDirectDisplayID: CGImage]) {
        var targets: [TargetDisplay] = []
        var frozen: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let image = LegacyScreenCapture.display(id) else { continue }
            targets.append(TargetDisplay(id: id, frame: screen.frame, backingScale: screen.backingScaleFactor))
            frozen[id] = image
        }
        return (targets, frozen)
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

    // MARK: - Annotation editor export

    /// Copies an edited image to the clipboard (annotation editor "copy"/"done").
    func editorCopy(_ image: NSImage) { copyToPasteboard(image) }

    /// Saves an edited image via a save panel (annotation editor "save").
    func editorSave(_ image: NSImage) {
        guard let png = image.pngData() else {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return
        }
        saveInteractive(png: png, existing: nil)
    }

    /// Pins an edited image on screen (annotation editor "pin").
    func editorPin(_ image: NSImage) {
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main
        PinnedImageWindow.show(image: image, at: screen?.frame ?? .zero)
    }

    private func recapture() {
        // The previous region rect is restored automatically from settings.
        capture(lastRegionRequest ?? CaptureRequest(mode: .region))
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
