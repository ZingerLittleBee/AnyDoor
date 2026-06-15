import Foundation

/// Pure description of the attached capture toolbar's buttons. Phase 2 shows
/// region / window / fullscreen (each is exactly a `CaptureMode`). Scrolling and
/// recording join in Phase 3 via a richer tool-type enum.
enum CaptureToolbarPolicy {
    /// Buttons rendered, left to right.
    static let tools: [CaptureToolType] = [.region, .window, .fullscreen, .scrolling, .recording]

    /// SF Symbol for each toolbar button.
    static func symbol(for tool: CaptureToolType) -> String {
        switch tool {
        case .region:     return "rectangle.dashed"
        case .window:     return "macwindow"
        case .fullscreen: return "rectangle.inset.filled"
        case .scrolling:  return "arrow.down.to.line"
        case .recording:  return "record.circle"
        }
    }

    /// Localized label key (reuses the existing mode-bar strings).
    static func labelKey(for tool: CaptureToolType) -> L10n.Key {
        switch tool {
        case .region:     return .captureModeBarRegion
        case .window:     return .captureModeBarWindow
        case .fullscreen: return .captureModeBarFullscreen
        case .scrolling:  return .captureModeBarScrolling
        case .recording:  return .captureModeBarRecording
        }
    }
}
