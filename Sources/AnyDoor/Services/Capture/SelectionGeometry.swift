import CoreGraphics
import Foundation

/// Pure geometry used by the selection overlay. No AppKit, no I/O.
enum SelectionGeometry {
    /// Minimum selectable edge length in points; smaller drags are treated as a
    /// stray click (cancellation).
    static let minimumEdge: CGFloat = 5

    /// Builds a normalized rect from two drag endpoints regardless of direction.
    static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Intersects `rect` with `bounds` so a selection can never leave the screen.
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        rect.intersection(bounds)
    }

    /// "W × H" using rounded integer points.
    static func formatDimensions(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) \u{00D7} \(Int(size.height.rounded()))"
    }

    static func isTooSmall(_ rect: CGRect) -> Bool {
        rect.width < minimumEdge || rect.height < minimumEdge
    }
}
