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

/// A resolved capture display: which screen to grab and the geometry needed to
/// size the selection overlay and convert selection points to pixels.
struct TargetDisplay: Sendable, Equatable {
    let id: CGDirectDisplayID
    /// The display's global AppKit frame (bottom-left origin), used to size and
    /// place the selection overlay.
    let frame: CGRect
    /// Pixels per point, for converting selection points into the frozen still's
    /// pixel space.
    let backingScale: CGFloat
}

/// What the selection overlay returns to the coordinator.
enum SelectionResult: Sendable {
    /// Region selected. The overlay already cropped its frozen backing still, so
    /// the image is returned directly (no second capture needed). `rect` is in
    /// global AppKit screen coordinates (bottom-left origin) for overlay placement.
    case region(image: CGImage, rect: CGRect)
    /// A window was picked; the coordinator grabs it crisply via `LegacyScreenCapture`.
    /// `frame` is the window's global AppKit screen frame for overlay placement.
    case window(id: CGWindowID, frame: CGRect)
    /// Whole-display capture chosen from the toolbar. The overlay returns its
    /// clean frozen still directly (no re-grab); `frame` is the display's global
    /// AppKit frame (for symmetry — the output overlay uses no anchor here).
    case fullscreen(image: CGImage, frame: CGRect)
    /// Scrolling capture requested on the current selection; `rect` is global
    /// AppKit coords. No image — the live scroll engine grabs after the overlay clears.
    case scrolling(rect: CGRect)
    /// Screen recording requested on the current selection; `rect` is global AppKit coords.
    case recording(rect: CGRect)
    case cancelled
}
