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

    /// Moves `rect` by (dx, dy), clamping so it stays fully inside `bounds`.
    /// Used by arrow-key nudging of an existing selection.
    static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat, in bounds: CGRect) -> CGRect {
        var x = rect.minX + dx
        var y = rect.minY + dy
        x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        y = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Grows/shrinks `rect` from its origin by (dw, dh), keeping at least
    /// `minimumEdge` per side and never exceeding `bounds`. Used by
    /// option-arrow resizing of an existing selection.
    static func resized(_ rect: CGRect, dw: CGFloat, dh: CGFloat, in bounds: CGRect) -> CGRect {
        let maxW = max(minimumEdge, bounds.maxX - rect.minX)
        let maxH = max(minimumEdge, bounds.maxY - rect.minY)
        let w = min(max(minimumEdge, rect.width + dw), maxW)
        let h = min(max(minimumEdge, rect.height + dh), maxH)
        return CGRect(x: rect.minX, y: rect.minY, width: w, height: h)
    }

    /// Places a magnifier loupe of `loupeSize` near `point` (the cursor), offset
    /// to the lower-right by `gap`, flipping to the opposite side when it would
    /// leave `bounds`. Keeps the loupe fully on-screen.
    static func loupeFrame(near point: CGPoint, loupeSize: CGFloat, gap: CGFloat, in bounds: CGRect) -> CGRect {
        var x = point.x + gap
        var y = point.y - gap - loupeSize
        if x + loupeSize > bounds.maxX { x = point.x - gap - loupeSize }
        if y < bounds.minY { y = point.y + gap }
        x = min(max(x, bounds.minX), bounds.maxX - loupeSize)
        y = min(max(y, bounds.minY), bounds.maxY - loupeSize)
        return CGRect(x: x, y: y, width: loupeSize, height: loupeSize)
    }

    /// The eight `handleSize`-square handle frames centered on the rect's
    /// corners and edge midpoints (y-up).
    static func handleRects(for rect: CGRect, handleSize: CGFloat) -> [SelectionHandle: CGRect] {
        let half = handleSize / 2
        func square(_ cx: CGFloat, _ cy: CGFloat) -> CGRect {
            CGRect(x: cx - half, y: cy - half, width: handleSize, height: handleSize)
        }
        return [
            .topLeft: square(rect.minX, rect.maxY),
            .top: square(rect.midX, rect.maxY),
            .topRight: square(rect.maxX, rect.maxY),
            .right: square(rect.maxX, rect.midY),
            .bottomRight: square(rect.maxX, rect.minY),
            .bottom: square(rect.midX, rect.minY),
            .bottomLeft: square(rect.minX, rect.minY),
            .left: square(rect.minX, rect.midY),
        ]
    }

    /// Classifies `p` against the selection: a handle (checked first, in a fixed
    /// order so overlaps are deterministic), the interior, or outside.
    static func hitTest(_ p: CGPoint, in rect: CGRect, handleSize: CGFloat) -> SelectionHit {
        let rects = handleRects(for: rect, handleSize: handleSize)
        for handle in SelectionHandle.allCases where rects[handle]?.contains(p) == true {
            return .handle(handle)
        }
        return rect.contains(p) ? .inside : .outside
    }
}

/// The eight resize anchors of a selection rectangle (y-up: `top` = maxY).
enum SelectionHandle: Equatable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// The part of a selection a point lands on, used to route a mouse-down to
/// resize / move / create-new.
enum SelectionHit: Equatable {
    case handle(SelectionHandle)
    case inside
    case outside
}
