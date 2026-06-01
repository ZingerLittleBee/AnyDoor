import AppKit
import ApplicationServices
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "windowLayout")

/// A single, atomic window layout operation requested by the user.
///
/// Covers Rectangle-style tiling against the focused window: halves,
/// quarters, thirds, two-thirds, plus next/previous-display moves.
/// Restore-previous-size and cycle behavior are intentionally out of scope.
enum WindowLayoutAction: String, Sendable, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case leftThird
    case centerThird
    case rightThird
    case leftTwoThirds
    case rightTwoThirds
    case maximize
    case center
    case moveToNextDisplay
    case moveToPreviousDisplay

    /// True only for actions whose target is a different display. The service
    /// routes these through `WindowLayoutGeometry.rectMovingToDisplay` instead
    /// of `targetRect`.
    var movesDisplay: Bool {
        switch self {
        case .moveToNextDisplay, .moveToPreviousDisplay: return true
        default: return false
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf:            return "rectangle.lefthalf.filled"
        case .rightHalf:           return "rectangle.righthalf.filled"
        case .topHalf:             return "rectangle.tophalf.filled"
        case .bottomHalf:          return "rectangle.bottomhalf.filled"
        case .topLeftQuarter:      return "square.split.2x2"
        case .topRightQuarter:     return "square.split.2x2"
        case .bottomLeftQuarter:   return "square.split.2x2"
        case .bottomRightQuarter:  return "square.split.2x2"
        case .leftThird:           return "rectangle.split.3x1"
        case .centerThird:         return "rectangle.split.3x1"
        case .rightThird:          return "rectangle.split.3x1"
        case .leftTwoThirds:       return "rectangle.split.3x1"
        case .rightTwoThirds:      return "rectangle.split.3x1"
        case .maximize:            return "arrow.up.left.and.arrow.down.right"
        case .center:              return "rectangle.center.inset.filled"
        case .moveToNextDisplay:   return "rectangle.on.rectangle"
        case .moveToPreviousDisplay: return "rectangle.on.rectangle"
        }
    }
}

/// Pure geometry used by the AX bridge. Kept separate so it can be unit
/// tested without spinning up the Accessibility API or `NSScreen`.
///
/// Both `windowFrame` and `visibleFrame` are expected in AX coordinate
/// space (origin top-left of the primary display, Y axis growing down).
/// The function only manipulates rectangles — coordinate conversion is
/// the AX bridge's job.
enum WindowLayoutGeometry {
    static func targetRect(
        action: WindowLayoutAction,
        windowFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        switch action {
        case .leftHalf:
            // floor() keeps left/right halves equal width even at odd or
            // fractional visible widths, at the cost of at most a 1pt
            // gutter — preferable to overlap.
            let half = floor(visibleFrame.width / 2)
            return CGRect(x: visibleFrame.minX,
                          y: visibleFrame.minY,
                          width: half,
                          height: visibleFrame.height)
        case .rightHalf:
            let half = floor(visibleFrame.width / 2)
            return CGRect(x: visibleFrame.maxX - half,
                          y: visibleFrame.minY,
                          width: half,
                          height: visibleFrame.height)
        case .maximize:
            return visibleFrame
        case .center:
            // Clamp oversized windows to the visible region, then center
            // the (possibly clamped) size inside it.
            let width = min(windowFrame.width, visibleFrame.width)
            let height = min(windowFrame.height, visibleFrame.height)
            let x = visibleFrame.minX + (visibleFrame.width - width) / 2
            let y = visibleFrame.minY + (visibleFrame.height - height) / 2
            return CGRect(x: x, y: y, width: width, height: height)
        case .topHalf:
            let half = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: visibleFrame.width, height: half)
        case .bottomHalf:
            let half = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.maxY - half,
                          width: visibleFrame.width, height: half)
        case .topLeftQuarter:
            let w = floor(visibleFrame.width / 2), h = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: w, height: h)
        case .topRightQuarter:
            let w = floor(visibleFrame.width / 2), h = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.maxX - w, y: visibleFrame.minY, width: w, height: h)
        case .bottomLeftQuarter:
            let w = floor(visibleFrame.width / 2), h = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.maxY - h, width: w, height: h)
        case .bottomRightQuarter:
            let w = floor(visibleFrame.width / 2), h = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.maxX - w, y: visibleFrame.maxY - h, width: w, height: h)
        case .leftThird:
            let third = floor(visibleFrame.width / 3)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: third, height: visibleFrame.height)
        case .rightThird:
            let third = floor(visibleFrame.width / 3)
            return CGRect(x: visibleFrame.maxX - third, y: visibleFrame.minY,
                          width: third, height: visibleFrame.height)
        case .centerThird:
            // Center absorbs the rounding remainder so left|center|right tile
            // the full width exactly: span from left third's right edge to
            // right third's left edge.
            let third = floor(visibleFrame.width / 3)
            let minX = visibleFrame.minX + third
            let maxX = visibleFrame.maxX - third
            return CGRect(x: minX, y: visibleFrame.minY,
                          width: maxX - minX, height: visibleFrame.height)
        case .leftTwoThirds:
            let twoThirds = floor(visibleFrame.width * 2 / 3)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: twoThirds, height: visibleFrame.height)
        case .rightTwoThirds:
            let twoThirds = floor(visibleFrame.width * 2 / 3)
            return CGRect(x: visibleFrame.maxX - twoThirds, y: visibleFrame.minY,
                          width: twoThirds, height: visibleFrame.height)
        case .moveToNextDisplay, .moveToPreviousDisplay:
            // Display-moving actions never reach targetRect; the service
            // routes them to rectMovingToDisplay. Harmless identity fallback.
            return visibleFrame
        }
    }
}

/// Reasons a `WindowLayoutService.apply(_:)` call may fail.
///
/// All paths surface as `Error`s the caller can format into a toast.
enum WindowLayoutError: Error, Sendable, Equatable {
    case missingAccessibilityPermission
    case noFrontmostApplication
    case noFocusedWindow
    case fullScreenWindowNotSupported
    case noScreenAvailable
    case axCallFailed(attribute: String, code: Int32)
}

/// Bridges layout actions into the Accessibility API.
///
/// `@MainActor`-isolated because `NSWorkspace.shared.frontmostApplication`
/// and `NSScreen.screens` are main-actor in Swift 6 strict mode. AX calls
/// themselves are thread-safe but cheap, so running on the main thread is
/// fine for the latency window of a hotkey press.
@MainActor
final class WindowLayoutService {
    static let shared = WindowLayoutService()

    private init() {}

    /// Apply `action` to the system's focused window.
    ///
    /// On success the function returns once `kAXPositionAttribute` and
    /// `kAXSizeAttribute` have been written. On failure throws a
    /// `WindowLayoutError`; callers (e.g., `WindowLayoutProvider`) are
    /// responsible for user-facing messaging.
    func apply(_ action: WindowLayoutAction) throws {
        guard AXIsProcessTrusted() else {
            throw WindowLayoutError.missingAccessibilityPermission
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowLayoutError.noFrontmostApplication
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let window = try copyFocusedWindow(from: axApp)
        try assertNotFullScreen(window)

        let currentFrame = try readFrame(of: window)
        let visible = try visibleFrameInAXCoords(containing: currentFrame)
        let target = WindowLayoutGeometry.targetRect(
            action: action,
            windowFrame: currentFrame,
            visibleFrame: visible
        )

        // Order matters on some apps: setting size before position avoids
        // a transient frame where the new position lands the old size off
        // the target display. The reverse can clip resizable insets in
        // Catalyst windows. Position-first is the more common convention
        // for Rectangle and works for the standard window classes we care
        // about here.
        try writePosition(of: window, to: target.origin)
        try writeSize(of: window, to: target.size)
    }

    // MARK: - AX helpers

    private func copyFocusedWindow(from axApp: AXUIElement) throws -> AXUIElement {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedWindowAttribute as CFString, &ref
        )
        guard err == .success, let value = ref else {
            // The app may simply have no focused window (e.g. Finder with
            // the desktop frontmost). Treat any non-success as no-window.
            throw WindowLayoutError.noFocusedWindow
        }
        // AX attribute returns an AXUIElement; the cast is safe because
        // kAXFocusedWindowAttribute is documented to return one.
        return value as! AXUIElement
    }

    private func assertNotFullScreen(_ window: AXUIElement) throws {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            window, "AXFullScreen" as CFString, &ref
        )
        // Attribute may legitimately be absent on apps that don't expose
        // it. Treat that as "not full-screen" rather than an error.
        if err == .success, let value = ref as? Bool, value {
            throw WindowLayoutError.fullScreenWindowNotSupported
        }
    }

    private func readFrame(of window: AXUIElement) throws -> CGRect {
        let position = try readPoint(of: window, attribute: kAXPositionAttribute)
        let size = try readSize(of: window, attribute: kAXSizeAttribute)
        return CGRect(origin: position, size: size)
    }

    private func readPoint(of element: AXUIElement, attribute: String) throws -> CGPoint {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success, let value = ref else {
            throw WindowLayoutError.axCallFailed(attribute: attribute, code: err.rawValue)
        }
        var point = CGPoint.zero
        let axValue = value as! AXValue
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            throw WindowLayoutError.axCallFailed(attribute: attribute, code: -1)
        }
        return point
    }

    private func readSize(of element: AXUIElement, attribute: String) throws -> CGSize {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success, let value = ref else {
            throw WindowLayoutError.axCallFailed(attribute: attribute, code: err.rawValue)
        }
        var size = CGSize.zero
        let axValue = value as! AXValue
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            throw WindowLayoutError.axCallFailed(attribute: attribute, code: -1)
        }
        return size
    }

    private func writePosition(of window: AXUIElement, to origin: CGPoint) throws {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else {
            throw WindowLayoutError.axCallFailed(attribute: kAXPositionAttribute, code: -1)
        }
        let err = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, value
        )
        guard err == .success else {
            throw WindowLayoutError.axCallFailed(attribute: kAXPositionAttribute, code: err.rawValue)
        }
    }

    private func writeSize(of window: AXUIElement, to size: CGSize) throws {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else {
            throw WindowLayoutError.axCallFailed(attribute: kAXSizeAttribute, code: -1)
        }
        let err = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, value
        )
        guard err == .success else {
            throw WindowLayoutError.axCallFailed(attribute: kAXSizeAttribute, code: err.rawValue)
        }
    }

    // MARK: - Coordinate conversion

    /// Returns the visible region (Dock + menu bar excluded) of the
    /// screen whose AX rect mostly overlaps `windowAXFrame`, converted
    /// into AX (top-left origin) coordinates.
    ///
    /// Falls back to the primary screen if no overlap can be determined,
    /// matching the "use main visibleFrame when matching is unreliable"
    /// rule.
    private func visibleFrameInAXCoords(containing windowAXFrame: CGRect) throws -> CGRect {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            throw WindowLayoutError.noScreenAvailable
        }
        let primaryHeight = primary.frame.height

        // Build AX rects for each screen and pick the one with the largest
        // intersection area with the window. Equal-area ties tip to the
        // earlier screen in `NSScreen.screens`, which matches the order
        // macOS reports.
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in screens {
            let frameAX = Self.toAXCoords(rect: screen.frame, primaryHeight: primaryHeight)
            let area = frameAX.intersection(windowAXFrame).standardized.area
            if best == nil || area > best!.area {
                best = (screen, area)
            }
        }

        let chosen = best?.screen ?? primary
        return Self.toAXCoords(rect: chosen.visibleFrame, primaryHeight: primaryHeight)
    }

    /// Convert a Cocoa-coordinate rect (origin bottom-left, Y up,
    /// referenced to the primary display) into AX coordinates (origin
    /// top-left of the primary display, Y down).
    nonisolated static func toAXCoords(rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
