import AppKit
import CoreGraphics

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
    private var onEnd: (() -> Void)?
    private var active = false

    private init() {}

    /// Begin a session for `viewport` (global AppKit coords). `onEnd` fires once
    /// when the session finishes (Done or Cancel) so the caller can release state.
    func start(viewport: CGRect, onEnd: @escaping () -> Void) {
        guard !active else { onEnd(); return }
        active = true
        self.viewport = viewport
        self.onEnd = onEnd
        self.accumulator = ScrollStitchAccumulator()
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
        if acc.ingest(frame), let img = acc.composite() {
            previewWindow.updatePreview(NSImage(cgImage: img, size: .zero), heightPx: acc.totalHeight)
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
