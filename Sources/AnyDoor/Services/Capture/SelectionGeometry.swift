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

    /// The vertical flip constant between AppKit (bottom-left) and CoreGraphics
    /// (top-left) **global** coordinate spaces. CoreGraphics anchors its global
    /// origin at the top-left of the PRIMARY display (the screen at AppKit origin
    /// `(0, 0)`), so the constant is the primary display's height — NOT the union
    /// of all displays. A secondary display extending above the primary must not
    /// change it. `screenFrames` are AppKit screen frames (e.g. `NSScreen.screens`).
    static func globalFlipHeight(screenFrames: [CGRect], fallback: CGFloat) -> CGFloat {
        let primary = screenFrames.first { $0.origin == .zero } ?? screenFrames.first
        return primary?.maxY ?? fallback
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

    /// Resizes `rect` by dragging `handle` to `point`, keeping the opposite
    /// edge/corner anchored, enforcing `minSize` per axis, and clamping the
    /// moving edges inside `bounds` (y-up). When the anchor edge sits within
    /// `minSize` of the bounds edge, the result may be smaller than `minSize`
    /// on that axis (bounds win over minSize).
    static func resizing(_ rect: CGRect, handle: SelectionHandle, to point: CGPoint, in bounds: CGRect, minSize: CGFloat) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY

        let movesLeft = handle == .topLeft || handle == .left || handle == .bottomLeft
        let movesRight = handle == .topRight || handle == .right || handle == .bottomRight
        let movesTop = handle == .topLeft || handle == .top || handle == .topRight
        let movesBottom = handle == .bottomLeft || handle == .bottom || handle == .bottomRight

        if movesLeft { minX = min(point.x, maxX - minSize) }
        if movesRight { maxX = max(point.x, minX + minSize) }
        if movesBottom { minY = min(point.y, maxY - minSize) }
        if movesTop { maxY = max(point.y, minY + minSize) }

        minX = max(minX, bounds.minX)
        maxX = min(maxX, bounds.maxX)
        minY = max(minY, bounds.minY)
        maxY = min(maxY, bounds.maxY)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A rectangle centered in `bounds`, each edge `fraction` of the
    /// corresponding bounds edge (fraction 0.5 = half width and half height).
    static func defaultCenteredRect(in bounds: CGRect, fraction: CGFloat) -> CGRect {
        let w = bounds.width * fraction
        let h = bounds.height * fraction
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Returns `last` when its center lies within one of `displays`, else nil —
    /// used to decide whether a persisted selection can be restored.
    static func restoredRect(last: CGRect?, displays: [CGRect]) -> CGRect? {
        guard let last, !last.isEmpty else { return nil }
        let center = CGPoint(x: last.midX, y: last.midY)
        return displays.contains(where: { $0.contains(center) }) ? last : nil
    }

    /// The selection rect to pre-show when opening the overlay (global AppKit
    /// coords): the persisted `last` rect clamped to the display holding its
    /// center, or — when there is no restorable rect — a half-size rect centered
    /// on the display under `mouse` (falling back to the first display). Returns
    /// `.zero` only when `displays` is empty. Shared by the region and scrolling
    /// capture coordinators so both remember the last selected viewport.
    static func initialSelectionRect(last: CGRect?, displays: [CGRect], mouse: CGPoint) -> CGRect {
        guard let first = displays.first else { return .zero }
        if let restored = restoredRect(last: last, displays: displays) {
            // Clamp to the display holding its center so a rect saved at a larger
            // resolution cannot pre-show off-screen edges after a display change.
            let center = CGPoint(x: restored.midX, y: restored.midY)
            let display = displays.first(where: { $0.contains(center) }) ?? first
            return clamped(restored, to: display)
        }
        let screen = displays.first(where: { $0.contains(mouse) }) ?? first
        return defaultCenteredRect(in: screen, fraction: 0.5)
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
