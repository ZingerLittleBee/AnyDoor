import Foundation
import PluginInterface

/// Action providers that drive the capture subsystem. Each one hops to the main
/// actor to call `CaptureCoordinator` (which is `@MainActor`); the coordinator
/// gates Screen Recording permission inline, so `permission` is `.notRequired`
/// here, mirroring `OCRProvider`.

/// Capture an interactive screen region (the repurposed `.screenshot` builtin).
actor CaptureRegionProvider: ActionProvider {
    let itemKey: BuiltinItem = .screenshot

    var permission: PermissionStatus { .notRequired }

    func run() async {
        await MainActor.run { CaptureCoordinator.shared.capture(CaptureRequest(mode: .region)) }
    }
}

/// Capture a single window.
actor CaptureWindowProvider: ActionProvider {
    let itemKey: BuiltinItem = .captureWindow

    var permission: PermissionStatus { .notRequired }

    func run() async {
        await MainActor.run { CaptureCoordinator.shared.capture(CaptureRequest(mode: .window)) }
    }
}

/// Capture the full screen.
actor CaptureFullscreenProvider: ActionProvider {
    let itemKey: BuiltinItem = .captureFullscreen

    var permission: PermissionStatus { .notRequired }

    func run() async {
        await MainActor.run { CaptureCoordinator.shared.capture(CaptureRequest(mode: .fullscreen)) }
    }
}

/// Capture a region after the configured self-timer countdown.
actor CaptureTimerProvider: ActionProvider {
    let itemKey: BuiltinItem = .captureTimer

    var permission: PermissionStatus { .notRequired }

    func run() async {
        await MainActor.run {
            CaptureCoordinator.shared.capture(
                CaptureRequest(mode: .region, delay: CaptureSettings.shared.delaySeconds)
            )
        }
    }
}

/// Toggle screen recording on/off (fullscreen of the display under the cursor).
actor RecordScreenProvider: ActionProvider {
    let itemKey: BuiltinItem = .recordScreen

    var permission: PermissionStatus { .notRequired }

    func run() async {
        await MainActor.run { RecordingCoordinator.shared.toggle() }
    }
}

/// Capture a scrollable area taller than the screen by stitching frames grabbed
/// while the user scrolls.
actor CaptureScrollingProvider: ActionProvider {
    let itemKey: BuiltinItem = .captureScrolling

    var permission: PermissionStatus { .notRequired }

    func run() async {
        await MainActor.run { ScrollCaptureCoordinator.shared.capture() }
    }
}
