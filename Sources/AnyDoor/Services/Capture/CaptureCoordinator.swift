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
    /// The running self-timer countdown, retained so Esc can cancel it.
    private var countdownTask: Task<Void, Never>?

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
    func deliverCapturedImage(_ image: CGImage) {
        present(image: image)
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
        SelectionGeometry.initialSelectionRect(
            last: settings.lastRegionRect, displays: targets.map(\.frame), mouse: NSEvent.mouseLocation
        )
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
            if delay > 0 {
                // Timed region: re-grab the live screen after the countdown so UI
                // arranged during it is captured — the frozen crop is now stale.
                afterCountdown(delay, anchor: rect, outline: rect) { [weak self] in
                    self?.captureLiveRegion(rect: rect)
                    self?.finish()
                }
            } else {
                self.present(image: cgImage)
                self.finish()
            }
        case let .regionTimer(rect):
            settings.setLastRegionRect(rect)
            // Clamp to >=1s: `delaySeconds` is portable via SyncSettingsRegistry and
            // unclamped, so an imported/edited 0 would skip the countdown's overlay
            // teardown and could re-grab the selection overlay into the shot.
            afterCountdown(max(1, settings.delaySeconds), anchor: rect, outline: rect) { [weak self] in
                self?.captureLiveRegion(rect: rect)
                self?.finish()
            }
        case let .window(id, frame):
            afterCountdown(delay, anchor: frame) { [weak self] in
                guard let self else { return }
                guard let cg = LegacyScreenCapture.window(id) else {
                    ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                    self.finish(); return
                }
                self.present(image: cg)
                self.finish()
            }
        case let .fullscreen(cgImage, frame):
            if delay > 0 {
                // Timed fullscreen: re-grab the live display after the countdown,
                // like region/window, so the frozen still is not stale.
                afterCountdown(delay, anchor: frame) { [weak self] in
                    self?.captureLiveFullscreen(frame: frame)
                    self?.finish()
                }
            } else {
                present(image: cgImage)
                finish()
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
            self.present(image: cg)
            self.finish()
        }
    }

    /// Grabs the live screen and crops it to `rect` (global AppKit coords,
    /// bottom-left origin), then runs it through the output policy. Used by the
    /// self-timer so the capture reflects the screen at countdown end, not the
    /// frozen still taken when the selection was made.
    private func captureLiveRegion(rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main,
              let id = screen.displayID,
              let full = LegacyScreenCapture.display(id) else {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return
        }
        let scale = screen.backingScaleFactor
        // Global AppKit rect (bottom-left) -> display-local pixel rect (top-left).
        let pixelRect = CGRect(
            x: (rect.minX - screen.frame.minX) * scale,
            y: (screen.frame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        guard let crop = full.cropping(to: pixelRect) else {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return
        }
        present(image: crop)
    }

    /// Re-grabs the live display containing `frame` (global AppKit coords) and runs
    /// it through the output policy. The timed fullscreen path uses this so the
    /// shot reflects the screen at countdown end, mirroring `captureLiveRegion`.
    private func captureLiveFullscreen(frame: CGRect) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main,
              let id = screen.displayID,
              let full = LegacyScreenCapture.display(id) else {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return
        }
        present(image: full)
    }

    /// Run `body` on the main actor after `seconds`, showing a visible per-second
    /// countdown overlay (placed in the lower-middle of the `anchor`'s display, or
    /// the display under the cursor) and, when `outline` is set, an accent border
    /// around the region being captured so the user can arrange UI inside it.
    ///
    /// Uses `Task.sleep` (which resumes on the main actor) — no cross-isolation
    /// await, so it is safe with respect to the executor-tracking bug described in
    /// `LegacyScreenCapture`. Both overlays are removed and given a brief beat to
    /// leave the screen before `body` runs, so a live re-grab never captures them.
    private func afterCountdown(_ seconds: Int, anchor: CGRect? = nil, outline: CGRect? = nil, _ body: @escaping @MainActor () -> Void) {
        guard seconds > 0 else { body(); return }
        let countdown = CaptureCountdownWindow()
        countdown.present(seconds: seconds, on: Self.countdownScreenFrame(anchor: anchor))
        let outlineWindow: CaptureRegionOutlineWindow?
        if let outline {
            let window = CaptureRegionOutlineWindow()
            window.present(frame: outline)
            outlineWindow = window
        } else {
            outlineWindow = nil
        }
        countdownTask = Task { @MainActor in
            defer { self.countdownTask = nil }
            var remaining = seconds
            while remaining > 0 {
                if Task.isCancelled { break }
                countdown.update(remaining: remaining)
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
            countdown.dismiss()
            outlineWindow?.dismiss()
            // Esc aborts the capture entirely: overlays are already torn down, so
            // just release the in-flight guard without grabbing.
            if Task.isCancelled { self.finish(); return }
            // Let the panels fully leave the screen before a live re-grab so they
            // are never in the shot. 140ms matches ScrollCaptureCoordinator's
            // vetted overlay-clear delay for the same teardown-then-live-grab
            // problem (orderOut only enqueues a compositor transaction).
            try? await Task.sleep(for: .milliseconds(140))
            body()
        }
        countdown.onCancel = { [weak self] in self?.countdownTask?.cancel() }
    }

    /// The display frame to anchor the countdown on: the display containing
    /// `anchor`'s center, else the display under the cursor (or main).
    @MainActor private static func countdownScreenFrame(anchor: CGRect?) -> CGRect {
        if let anchor {
            let center = CGPoint(x: anchor.midX, y: anchor.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen.frame
            }
        }
        return (NSScreen.screenUnderMouse ?? NSScreen.main)?.frame ?? .zero
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

    /// Apply output policy and show the quick-access overlay. The PNG encode and
    /// auto-save disk write run OFF the main actor (a fullscreen Retina/5K grab
    /// is tens of MB; doing them inline beachballed the menu bar / all UI until
    /// the shot landed). The clipboard copy stays inline so it is ready instantly;
    /// the overlay + toast resume on the main actor once the heavy work finishes.
    ///
    /// Safe w.r.t. the SCK executor-tracking bug documented on the type: the
    /// capture grab is already complete and synchronous, and this mirrors the
    /// existing off-main OCR / history paths below.
    private func present(image cg: CGImage) {
        // Shutter feedback at the capture's commit moment, matching native
        // screenshots. NSSound plays asynchronously, so this never blocks.
        if settings.playSound { SystemSound.screenCapture.play() }

        let image = NSImage(cgImage: cg, size: .zero)

        // Cheap and latency-sensitive: copy to the pasteboard right away (AppKit
        // encodes the bitmap lazily) so the clipboard is ready the instant the
        // shot lands, before the PNG encode below.
        if settings.autoCopy {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: pb.changeCount)
        }

        // Snapshot the main-actor settings the off-main save needs (all Sendable).
        let autoSave = settings.autoSave
        let saveDir = settings.saveDirectory
        let template = settings.namingTemplate
        let overlayTimeout = settings.overlayTimeout

        // A Task from a @MainActor method inherits MainActor isolation, so the
        // overlay/toast code after each `await` resumes on the main actor; only
        // the encode/write hop to a detached executor.
        Task { [weak self] in
            let png: Data? = await Task.detached(priority: .userInitiated) {
                NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }.value
            guard let self else { return }
            guard let png else {
                ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                return
            }

            var savedURL: URL?
            if autoSave {
                savedURL = await Task.detached(priority: .userInitiated) {
                    Self.writePNG(png, to: saveDir, namingTemplate: template)
                }.value
                if savedURL != nil {
                    ToastPresenter.shared.show(.success(L(.captureToastSaved, saveDir.lastPathComponent)))
                } else {
                    ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                }
            }

            // Shared box so the delete action can remove the exact history entry
            // once the async record completes (both hops run on the main actor).
            let recordedID = HistoryIDBox()
            Task { recordedID.value = await ClipboardHistoryStore.shared.recordScreenshot(pngData: png) }

            let actions = CaptureOverlayActions(
                copy: { [weak self] in self?.copyToPasteboard(image) },
                save: { [weak self] in self?.saveAs(png: png) },
                // Only offered when auto-save already wrote the file to disk.
                reveal: savedURL.map { url in { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
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
                image: image, fileURL: savedURL,
                timeout: overlayTimeout, actions: actions
            )
        }
    }

    /// Pure, off-main PNG file write for auto-save. Returns the written URL, or
    /// nil on failure (the caller shows the toast on the main actor).
    private nonisolated static func writePNG(_ png: Data, to directory: URL, namingTemplate: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = CaptureFilename.make(template: namingTemplate, date: Date(), calendar: .current)
            let name = CaptureFilename.resolve(base: base, ext: "png") {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            let url = directory.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// "Save As": always prompt for a destination via a save panel.
    private func saveAs(png: Data) {
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
        saveAs(png: png)
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
