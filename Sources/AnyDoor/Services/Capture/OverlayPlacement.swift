import CoreGraphics
import Foundation

/// Pure placement of the quick-access overlay relative to a captured region.
/// Global AppKit screen coordinates (bottom-left origin). No AppKit dependency.
enum OverlayPlacement {
    /// Centers the overlay horizontally under the region (flipping above if there
    /// is no room below), then clamps the whole frame inside the screen.
    static func frame(forRegion region: CGRect, overlaySize: CGSize, onScreen screen: CGRect, gap: CGFloat) -> CGRect {
        let x = region.midX - overlaySize.width / 2
        // Prefer below the region (smaller y). If it would clip the bottom, flip above.
        var y = region.minY - gap - overlaySize.height
        if y < screen.minY {
            y = region.maxY + gap
        }
        let proposed = CGRect(x: x, y: y, width: overlaySize.width, height: overlaySize.height)
        return clampInside(proposed, screen: screen)
    }

    /// Bottom-left of the screen — the fixed home of the quick-access overlay.
    /// Pass the screen's *visible* frame so the overlay clears the Dock and menu bar.
    static func bottomLeftFrame(overlaySize: CGSize, onScreen visible: CGRect, margin: CGFloat) -> CGRect {
        CGRect(
            x: visible.minX + margin,
            y: visible.minY + margin,
            width: overlaySize.width,
            height: overlaySize.height
        )
    }

    private static func clampInside(_ rect: CGRect, screen: CGRect) -> CGRect {
        var r = rect
        if r.maxX > screen.maxX { r.origin.x = screen.maxX - r.width }
        if r.minX < screen.minX { r.origin.x = screen.minX }
        if r.maxY > screen.maxY { r.origin.y = screen.maxY - r.height }
        if r.minY < screen.minY { r.origin.y = screen.minY }
        return r
    }
}
