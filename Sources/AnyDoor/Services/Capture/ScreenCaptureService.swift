import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Errors from the capture engine.
enum CaptureError: Error {
    case permissionDenied
    case noShareableContent
    case targetNotFound
    case captureFailed
}

/// Serializes ScreenCaptureKit still captures (macOS 14+). All grabs go through
/// one actor so concurrent capture requests can't race the shared SCK machinery.
actor ScreenCaptureService {
    static let shared = ScreenCaptureService()

    /// Full still of a display.
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else {
            throw CaptureError.targetNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // SCDisplay width/height are in points; SCStreamConfiguration width/height
        // are in pixels. Multiply by the display's backing scale so the still is at
        // native pixel resolution (sharp fullscreen, and a correct Retina region crop).
        let scale = Self.backingScale(for: displayID)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        return try await capture(filter: filter, config: config)
    }

    /// Backing scale (pixels per point) for a display, via its current mode.
    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 1 }
        let points = mode.width
        let pixels = mode.pixelWidth
        guard points > 0 else { return 1 }
        return CGFloat(pixels) / CGFloat(points)
    }

    /// Crisp capture of a single window, preserving transparency and shadow.
    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.targetNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = window.frame.width > 0 ? 2 : 1 // request native size; SCK applies backing scale
        config.width = Int(window.frame.width) * scale
        config.height = Int(window.frame.height) * scale
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = false
        return try await capture(filter: filter, config: config)
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard ScreenCapturePermission.isGranted || ScreenCapturePermission.request() else {
            throw CaptureError.permissionDenied
        }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noShareableContent
        }
    }

    private func capture(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed
        }
    }
}
