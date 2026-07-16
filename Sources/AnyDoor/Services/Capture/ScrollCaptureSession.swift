import AppKit
import CoreGraphics
import PluginInterface

/// Interactive scrolling capture: shows a preview + Done/Cancel, observes real
/// scroll events, grabs the viewport (below its own preview window so the session
/// UI is never in the shot), stitches live, and delivers via the output policy.
/// @MainActor, monitor/timer-driven; the only capture is the synchronous
/// `LegacyScreenCapture.belowWindow`, so no cross-isolation await occurs.
@MainActor
final class ScrollCaptureSession {
    static let shared = ScrollCaptureSession()

    private let previewWindow = ScrollCaptureSessionWindow()
    private let outlineWindow = ScrollViewportOutlineWindow()
    private var accumulator: ScrollStitchAccumulator?
    private var viewport: CGRect = .zero
    private var primaryMaxY: CGFloat = 0
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var trailingTimer: Timer?
    private var lastGrab = Date.distantPast
    private var lastPreviewComposite = Date.distantPast
    private var onEnd: (() -> Void)?
    private var active = false

    /// Min interval between live-preview recomposites. Rebuilding the full
    /// stitched bitmap gets costly as the page grows, and the preview doesn't
    /// need every ~0.06s grab; the final composite at finishSession is full.
    private static let previewComposeInterval: TimeInterval = 0.15

    private init() {}

    /// Begin a session for `viewport` (global AppKit coords). `onEnd` fires once
    /// when the session finishes (Done or Cancel) so the caller can release state.
    func start(viewport: CGRect, onEnd: @escaping () -> Void) {
        guard !active else { onEnd(); return }
        active = true
        self.viewport = viewport
        self.onEnd = onEnd
        self.accumulator = ScrollStitchAccumulator()
        self.lastPreviewComposite = .distantPast
        self.primaryMaxY = NSScreen.screens.first?.frame.maxY ?? viewport.maxY

        // Preview first, then outline ordered above it, so the below-preview grab
        // excludes both session windows.
        previewWindow.present(viewport: viewport,
            onDone: { [weak self] in self?.finishSession(deliver: true) },
            onCancel: { [weak self] in self?.finishSession(deliver: false) })
        outlineWindow.present(frame: viewport)

        grabAndIngest()   // seed with the first frame

        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainThreadIsolation.run { self?.handleScroll() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            MainThreadIsolation.run { if code == 53 { self?.finishSession(deliver: false) } }
        }
    }

    private func handleScroll() {
        guard active else { return }
        if Date().timeIntervalSince(lastGrab) >= 0.06 { grabAndIngest() }
        // Trailing grab to capture the resting position after the scroll stops.
        trailingTimer?.invalidate()
        trailingTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainThreadIsolation.run { self?.grabAndIngest() }
        }
    }

    private func grabAndIngest() {
        guard active, let acc = accumulator, previewWindow.windowNumber > 0 else { return }
        lastGrab = Date()
        let cg = CGRect(x: viewport.minX, y: primaryMaxY - viewport.maxY,
                        width: viewport.width, height: viewport.height)
        guard let frame = LegacyScreenCapture.belowWindow(CGWindowID(previewWindow.windowNumber), bounds: cg) else { return }
        guard acc.ingest(frame) else { return }

        // Throttle the live-preview recomposite (the full-bitmap rebuild is the
        // hot per-frame cost); the resting trailing grab is >0.15s after a scroll
        // stops, so the settled preview is always current.
        let now = Date()
        if now.timeIntervalSince(lastPreviewComposite) >= Self.previewComposeInterval, let img = acc.composite() {
            lastPreviewComposite = now
            previewWindow.updatePreview(NSImage(cgImage: img, size: .zero), heightPx: acc.totalHeight)
        }

        // Stop accumulating once the runaway memory guards trip; deliver what we
        // have (finishSession does a final full composite) rather than growing
        // the slice array / stitched image without bound.
        if acc.hasReachedCaptureLimit() {
            finishSession(deliver: true)
        }
    }

    private func finishSession(deliver: Bool) {
        guard active else { return }
        active = false
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil; keyMonitor = nil
        trailingTimer?.invalidate(); trailingTimer = nil

        let image = deliver ? accumulator?.composite() : nil
        accumulator = nil
        outlineWindow.dismiss()
        previewWindow.dismiss()

        if deliver {
            if let image {
                CaptureCoordinator.shared.deliverCapturedImage(image)
            } else {
                ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            }
        }
        let cb = onEnd; onEnd = nil; cb?()
    }
}
