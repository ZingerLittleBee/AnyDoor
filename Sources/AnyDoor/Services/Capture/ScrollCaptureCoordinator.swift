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

    /// Entry point (mode bar / builtin / hotkey): select a viewport, then
    /// auto-scroll and stitch it into one tall image.
    func capture() {
        guard !inFlight else { return }
        guard ScreenCapturePermission.ensureGranted() else {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            ScreenCapturePermission.openSettings()
            return
        }
        inFlight = true

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
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = targets.first(where: { $0.frame.contains(center) }) ?? targets.first else {
                self.finish(); return
            }
            // Let the selection overlay fully clear the screen before the first
            // grab, so the stitched image never includes the overlay chrome.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                self.engine.capture(viewport: rect, display: display) { [weak self] image in
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
    }

    private func finish() { inFlight = false }
}
