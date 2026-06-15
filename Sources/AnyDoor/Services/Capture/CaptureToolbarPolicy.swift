import Foundation

/// Pure description of the attached capture toolbar's buttons. Phase 2 shows
/// region / window / fullscreen (each is exactly a `CaptureMode`). Scrolling and
/// recording join in Phase 3 via a richer tool-type enum.
enum CaptureToolbarPolicy {
    /// Buttons rendered, left to right.
    static let modes: [CaptureMode] = [.region, .window, .fullscreen]

    /// SF Symbol for each toolbar button.
    static func symbol(for mode: CaptureMode) -> String {
        switch mode {
        case .region:     return "rectangle.dashed"
        case .window:     return "macwindow"
        case .fullscreen: return "rectangle.inset.filled"
        }
    }

    /// Localized label key (reuses the existing mode-bar strings).
    static func labelKey(for mode: CaptureMode) -> L10n.Key {
        switch mode {
        case .region:     return .captureModeBarRegion
        case .window:     return .captureModeBarWindow
        case .fullscreen: return .captureModeBarFullscreen
        }
    }
}
