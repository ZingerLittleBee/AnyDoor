import CoreGraphics
import Foundation

/// An on-screen window candidate for window-mode capture. `frame` is in global
/// CoreGraphics coordinates (top-left origin), as returned by CGWindowList.
struct CapturableWindow: Sendable, Equatable {
    let id: CGWindowID
    let frame: CGRect
}

enum WindowEnumerator {
    /// The frontmost window whose frame contains `point`. `windows` must be ordered
    /// front-to-back (CGWindowList's natural order). Pure — unit-testable.
    static func window(under point: CGPoint, in windows: [CapturableWindow]) -> CapturableWindow? {
        windows.first { $0.frame.contains(point) }
    }

    /// Live on-screen windows at layer 0 (normal app windows), front-to-back.
    /// Excludes the desktop, menu bar, and our own overlay windows by layer.
    static func onScreenWindows() -> [CapturableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let number = info[kCGWindowNumber as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return CapturableWindow(id: CGWindowID(number), frame: bounds)
        }
    }
}
