import CoreGraphics
import Foundation

/// The three primitive capture modes. `timer` is not a mode — it is any of these
/// run after a countdown (see `CaptureRequest.delay`).
enum CaptureMode: String, Sendable, CaseIterable {
    case region
    case window
    case fullscreen
}

/// A capture the coordinator should perform. `delay` is the self-timer countdown
/// in seconds (0 = immediate). For `region`/`window`, selection happens first,
/// then the countdown, then the grab — so the user can arrange transient UI.
struct CaptureRequest: Sendable, Equatable {
    let mode: CaptureMode
    let delay: Int

    init(mode: CaptureMode, delay: Int = 0) {
        self.mode = mode
        self.delay = max(0, delay)
    }
}

/// A resolved capture source handed to `ScreenCaptureService`.
enum CaptureTarget: Sendable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// A sub-rectangle of a display, in that display's local top-left points.
    case rect(CGRect, display: CGDirectDisplayID)
}

/// What the selection overlay returns to the coordinator.
enum SelectionResult: Sendable {
    /// Region selected. The overlay already cropped its frozen backing still, so
    /// the image is returned directly (no second capture needed). `rect` is in
    /// global AppKit screen coordinates (bottom-left origin) for overlay placement.
    case region(image: CGImage, rect: CGRect)
    /// A window was picked; the coordinator captures it crisply via ScreenCaptureKit.
    /// `frame` is the window's global AppKit screen frame for overlay placement.
    case window(id: CGWindowID, frame: CGRect)
    case cancelled
}
