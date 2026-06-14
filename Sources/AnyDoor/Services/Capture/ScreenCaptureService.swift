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
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        return try await capture(filter: filter, config: config)
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
