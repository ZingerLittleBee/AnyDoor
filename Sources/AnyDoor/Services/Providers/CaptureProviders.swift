import Foundation

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

/// Present the floating capture mode bar.
actor CaptureModeBarProvider: ActionProvider {
    let itemKey: BuiltinItem = .captureModeBar

    var permission: PermissionStatus { .notRequired }

    func run() async {
        await MainActor.run { CaptureCoordinator.shared.presentModeBar() }
    }
}
