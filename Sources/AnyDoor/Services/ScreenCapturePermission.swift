import AppKit
import CoreGraphics
import Foundation

enum ScreenCapturePermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func ensureGranted() -> Bool {
        isGranted || request()
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
