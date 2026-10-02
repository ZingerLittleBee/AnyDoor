import Foundation

/// Pure description of the attached capture toolbar's buttons: which tools it
/// shows, in order, and each tool's symbol and label.
enum CaptureToolbarPolicy {
    /// Buttons rendered, left to right.
    static let tools: [CaptureToolType] = [.region, .window, .fullscreen, .timer, .scrolling, .recording]

    /// SF Symbol for each toolbar button.
    static func symbol(for tool: CaptureToolType) -> String {
        switch tool {
        case .region:     return "rectangle.dashed"
        case .window:     return "macwindow"
        case .fullscreen: return "rectangle.inset.filled"
        case .timer:      return "timer"
        case .scrolling:  return "arrow.down.to.line"
        case .recording:  return "record.circle"
        }
    }

    /// Localized label key for each toolbar button.
    static func labelKey(for tool: CaptureToolType) -> L10n.Key {
        switch tool {
        case .region:     return .captureToolbarRegion
        case .window:     return .captureToolbarWindow
        case .fullscreen: return .captureToolbarFullscreen
        case .timer:      return .captureToolbarTimer
        case .scrolling:  return .captureToolbarScrolling
        case .recording:  return .captureToolbarRecording
        }
    }
}
