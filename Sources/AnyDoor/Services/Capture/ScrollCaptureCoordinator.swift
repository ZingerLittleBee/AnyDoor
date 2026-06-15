import AppKit
import CoreGraphics

/// Orchestrates a scrolling capture: permission check -> resolve the viewport
/// (region handoff from the toolbar, or the built-in selection overlay) ->
/// hand off to the interactive `ScrollCaptureSession`. `@MainActor`, callback-based.
@MainActor
final class ScrollCaptureCoordinator {
    static let shared = ScrollCaptureCoordinator()
    private let selectionOverlay = SelectionOverlayWindow()
    private var inFlight = false
    private init() {}

    /// Entry point. `region` (global AppKit coords) skips the built-in viewport
    /// selection (used by the unified capture toolbar). `nil` presents the overlay
    /// to let the user pick a viewport.
    func capture(region: CGRect? = nil) {
        guard !inFlight else { return }
        guard ScreenCapturePermission.ensureGranted() else {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            ScreenCapturePermission.openSettings()
            return
        }
        inFlight = true

        if let region { startSession(viewport: region); return }

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
            self.startSession(viewport: rect)
        }
    }

    private func startSession(viewport: CGRect) {
        // Let any selection overlay fully clear before the session's first grab.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            ScrollCaptureSession.shared.start(viewport: viewport) { [weak self] in self?.finish() }
        }
    }

    private func finish() { inFlight = false }
}
