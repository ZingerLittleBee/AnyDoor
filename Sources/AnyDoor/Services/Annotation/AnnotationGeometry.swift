import CoreGraphics
import Foundation

/// Pure geometry for the annotation editor. No AppKit, no I/O — unit tested.
enum AnnotationGeometry {
    /// The two barb endpoints of an arrowhead drawn at `to`, pointing back along
    /// the line from `from`. `length` is the barb length (pixels) and `spread` the
    /// half-angle between each barb and the shaft (radians).
    static func arrowHead(
        from: CGPoint,
        to: CGPoint,
        length: CGFloat,
        spread: CGFloat = .pi / 7
    ) -> (left: CGPoint, right: CGPoint) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let left = CGPoint(
            x: to.x - length * cos(angle - spread),
            y: to.y - length * sin(angle - spread)
        )
        let right = CGPoint(
            x: to.x - length * cos(angle + spread),
            y: to.y - length * sin(angle + spread)
        )
        return (left, right)
    }

    /// A circle's bounding rect for a counter badge centered at `center`.
    static func counterCircleRect(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Clamps a crop rect to the image bounds, normalizing direction first. A rect
    /// that does not intersect the image collapses to an empty rect at the origin.
    static func clampCrop(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let normalized = CGRect(
            x: min(rect.minX, rect.maxX),
            y: min(rect.minY, rect.maxY),
            width: abs(rect.width),
            height: abs(rect.height)
        )
        return normalized.intersection(bounds)
    }

    /// Distance from a point to the segment a-b.
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    /// Whether `point` hits `element`, within `tolerance` pixels for thin shapes.
    static func hitTest(_ point: CGPoint, element: AnnotationElement, tolerance: CGFloat = 8) -> Bool {
        switch element.kind {
        case let .arrow(from, to), let .line(from, to):
            return distance(from: point, toSegment: from, to) <= tolerance
        case let .rectangle(rect), let .ellipse(rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case let .blur(rect), let .pixelate(rect), let .redaction(rect):
            return rect.contains(point)
        case let .freehand(points), let .highlighter(points):
            guard points.count > 1 else {
                return points.first.map { hypot(point.x - $0.x, point.y - $0.y) <= tolerance } ?? false
            }
            for i in 0..<(points.count - 1) where distance(from: point, toSegment: points[i], points[i + 1]) <= tolerance {
                return true
            }
            return false
        case let .text(_, origin):
            // Coarse: a box around the origin scaled by font size.
            let box = CGRect(x: origin.x, y: origin.y, width: element.style.fontSize * 6, height: element.style.fontSize * 1.4)
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case let .counter(_, center):
            let r = counterRadius(for: element.style)
            return hypot(point.x - center.x, point.y - center.y) <= r + tolerance
        }
    }

    /// The counter badge radius derived from its style's font size.
    static func counterRadius(for style: AnnotationStyle) -> CGFloat {
        max(14, style.fontSize)
    }
}
