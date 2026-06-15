import AppKit
import CoreGraphics

/// Orchestrates a scrolling capture: permission check -> region selection (the
/// scroll viewport) -> `ScrollCaptureEngine` -> the shared capture output policy.
/// `@MainActor`, callback-based, mirroring `RecordingCoordinator`.
@MainActor
final class ScrollCaptureCoordinator {
    static let shared = ScrollCaptureCoordinator()

    private let engine = ScrollCaptureEngine()
    private let selectionOverlay = SelectionOverlayWindow()
    private var inFlight = false

    private init() {}

    /// Entry point. `region` (global AppKit coords) skips the built-in viewport
    /// selection — used by the unified capture toolbar, which already has a
    /// selection. `nil` keeps the standalone flow: freeze displays, let the user
    /// pick a viewport, then scroll+stitch.
    func capture(region: CGRect? = nil) {
        guard !inFlight else { return }
        guard ScreenCapturePermission.ensureGranted() else {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            ScreenCapturePermission.openSettings()
            return
        }
        inFlight = true

        if let region {
            runEngine(viewport: region)
            return
        }

        var frozen: [CGDirectDisplayID: CGImage] = [:]
        var targets: [TargetDisplay] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let img = LegacyScreenCapture.display(id) else { continue }
            targets.append(TargetDisplay(id: id, frame: screen.frame, backingScale: screen.backingScaleFactor))
            frozen[id] = img
        }
        guard !targets.isEmpty else { finish(); return }

        selectionOverlay.present(targets: targets, mode: .region, frozen: frozen) { [weak self] result in
            guard let self else { return }
            guard case let .region(_, rect) = result else { self.finish(); return }
            self.runEngine(viewport: rect)
        }
    }

    /// Derive the display under the viewport, let the screen clear, then scroll+stitch.
    private func runEngine(viewport rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let display = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screenUnderMouse ?? NSScreen.main
        guard let display, let id = display.displayID else { finish(); return }
        let target = TargetDisplay(id: id, frame: display.frame, backingScale: display.backingScaleFactor)
        // Let the overlay (built-in or the unified toolbar's) fully clear before the
        // first grab, so the stitched image never includes overlay chrome.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            self.engine.capture(viewport: rect, display: target) { [weak self] image in
                guard let self else { return }
                if let image {
                    CaptureCoordinator.shared.deliverCapturedImage(image, anchor: rect)
                } else {
                    ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                }
                self.finish()
            }
        }
    }

    private func finish() { inFlight = false }
}
