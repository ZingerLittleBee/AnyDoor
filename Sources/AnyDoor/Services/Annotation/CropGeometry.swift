import CoreGraphics
import Foundation

enum CropAspectPreset: String, CaseIterable, Identifiable, Sendable {
    case freeform
    case original
    case square
    case fourThree
    case threeTwo
    case sixteenNine

    var id: String { rawValue }

    var allowsOrientationFlip: Bool {
        switch self {
        case .fourThree, .threeTwo, .sixteenNine:
            return true
        case .freeform, .original, .square:
            return false
        }
    }

    func ratio(imageBounds: CGRect, flipped: Bool) -> CGFloat? {
        let base: CGFloat?
        switch self {
        case .freeform:
            base = nil
        case .original:
            base = imageBounds.height > 0 ? imageBounds.width / imageBounds.height : nil
        case .square:
            base = 1
        case .fourThree:
            base = 4 / 3
        case .threeTwo:
            base = 3 / 2
        case .sixteenNine:
            base = 16 / 9
        }
        guard let base, base > 0 else { return nil }
        return flipped && allowsOrientationFlip ? 1 / base : base
    }
}

struct CropSession: Equatable, Sendable {
    var initialRect: CGRect
    var rect: CGRect
    var imageBounds: CGRect
    var aspectPreset: CropAspectPreset
    var aspectFlipped: Bool

    init(initialRect: CGRect, imageBounds: CGRect) {
        let bounds = imageBounds.standardized
        let clamped = CropGeometry.clampRect(initialRect, to: bounds)
        self.initialRect = clamped
        self.rect = clamped
        self.imageBounds = bounds
        self.aspectPreset = .freeform
        self.aspectFlipped = false
    }

    var activeAspectRatio: CGFloat? {
        aspectPreset.ratio(imageBounds: imageBounds, flipped: aspectFlipped)
    }
}

enum CropHandle: CaseIterable, Equatable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return true
        case .top, .right, .bottom, .left:
            return false
        }
    }
}

enum CropHitTarget: Equatable, Sendable {
    case handle(CropHandle)
    case inside
    case outside
}

enum CropCommitAction: Equatable, Sendable {
    case noOp
    case clear
    case set(CGRect)
}

enum CropGeometry {
    static let minimumSize: CGFloat = 8
    private static let handleVisualThickness: CGFloat = 3
    private static let cornerHandleVisualLength: CGFloat = 19
    private static let edgeHandleVisualLength: CGFloat = 22
    private static let visualHandleHitPadding: CGFloat = 3
    private static let baseHandleHitThickness: CGFloat = max(minimumSize, handleVisualThickness)
    private static let baseHandleHitLength: CGFloat = max(cornerHandleVisualLength, edgeHandleVisualLength) + visualHandleHitPadding * 2

    static func clampPoint(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: clamp(point.x, min: bounds.minX, max: bounds.maxX),
            y: clamp(point.y, min: bounds.minY, max: bounds.maxY)
        )
    }

    static func clampRect(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let standardized = rect.standardized
        let intersection = standardized.intersection(bounds.standardized)
        guard !intersection.isNull else {
            return CGRect(origin: bounds.origin, size: .zero)
        }
        return intersection
    }

    static func handleCenter(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        let r = rect.standardized
        switch handle {
        case .topLeft:
            return CGPoint(x: r.minX, y: r.minY)
        case .top:
            return CGPoint(x: r.midX, y: r.minY)
        case .topRight:
            return CGPoint(x: r.maxX, y: r.minY)
        case .right:
            return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight:
            return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom:
            return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft:
            return CGPoint(x: r.minX, y: r.maxY)
        case .left:
            return CGPoint(x: r.minX, y: r.midY)
        }
    }

    static func hitTest(point: CGPoint, viewRect: CGRect, tolerance: CGFloat = 10) -> CropHitTarget {
        let rect = viewRect.standardized
        guard rect.width > 0, rect.height > 0 else { return .outside }
        let hits = CropHandle.allCases.filter { handleHitRect($0, in: rect, tolerance: tolerance).contains(point) }
        if let nearest = hits.min(by: { distanceSquared(point, handleCenter($0, in: rect)) < distanceSquared(point, handleCenter($1, in: rect)) }) {
            return .handle(nearest)
        }
        return rect.contains(point) ? .inside : .outside
    }

    static func handleHitRect(_ handle: CropHandle, in rect: CGRect, tolerance: CGFloat = 10) -> CGRect {
        let center = handleCenter(handle, in: rect)
        let thick = baseHandleHitThickness + tolerance * 2
        let long = baseHandleHitLength + tolerance * 2
        let size: CGSize
        switch handle {
        case .top, .bottom:
            size = CGSize(width: long, height: thick)
        case .left, .right:
            size = CGSize(width: thick, height: long)
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            size = CGSize(width: long, height: long)
        }
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    static func snapAspect(rect: CGRect, ratio: CGFloat, in bounds: CGRect) -> CGRect {
        let imageBounds = bounds.standardized
        guard ratio > 0, imageBounds.width > 0, imageBounds.height > 0 else {
            return clampRect(rect, to: imageBounds)
        }
        let current = clampRect(rect, to: imageBounds)
        let center = clampPoint(CGPoint(x: current.midX, y: current.midY), to: imageBounds)
        let maxWidth = max(0, min(center.x - imageBounds.minX, imageBounds.maxX - center.x) * 2)
        let maxHeight = max(0, min(center.y - imageBounds.minY, imageBounds.maxY - center.y) * 2)
        var width = maxWidth
        var height = width / ratio
        if height > maxHeight {
            height = maxHeight
            width = height * ratio
        }
        return centeredRect(center: center, size: CGSize(width: width, height: height))
    }

    static func move(rect: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        let imageBounds = bounds.standardized
        let current = clampRect(rect, to: imageBounds)
        guard current.width < imageBounds.width || current.height < imageBounds.height else {
            return current
        }
        let x = clamp(current.minX + delta.dx, min: imageBounds.minX, max: imageBounds.maxX - current.width)
        let y = clamp(current.minY + delta.dy, min: imageBounds.minY, max: imageBounds.maxY - current.height)
        return CGRect(x: x, y: y, width: current.width, height: current.height)
    }

    static func nudge(rect: CGRect, dx: CGFloat, dy: CGFloat, in bounds: CGRect) -> CGRect {
        move(rect: rect, by: CGVector(dx: dx, dy: dy), in: bounds)
    }

    static func resize(rect: CGRect, handle: CropHandle, to point: CGPoint, in bounds: CGRect, aspectRatio: CGFloat?) -> CGRect {
        if let aspectRatio, aspectRatio > 0 {
            return handle.isCorner
                ? resizeCornerWithAspect(rect: rect, handle: handle, to: point, in: bounds, ratio: aspectRatio)
                : resizeEdgeWithAspect(rect: rect, handle: handle, to: point, in: bounds, ratio: aspectRatio)
        }
        return handle.isCorner
            ? resizeCornerFreeform(rect: rect, handle: handle, to: point, in: bounds)
            : resizeEdgeFreeform(rect: rect, handle: handle, to: point, in: bounds)
    }

    static func drawNewRect(anchor: CGPoint, to point: CGPoint, in bounds: CGRect, aspectRatio: CGFloat?) -> CGRect {
        let imageBounds = bounds.standardized
        let anchor = clampPoint(anchor, to: imageBounds)
        let point = clampPoint(point, to: imageBounds)
        let signX = preferredSign(delta: point.x - anchor.x, negativeSpace: anchor.x - imageBounds.minX, positiveSpace: imageBounds.maxX - anchor.x)
        let signY = preferredSign(delta: point.y - anchor.y, negativeSpace: anchor.y - imageBounds.minY, positiveSpace: imageBounds.maxY - anchor.y)
        let maxWidth = signX < 0 ? anchor.x - imageBounds.minX : imageBounds.maxX - anchor.x
        let maxHeight = signY < 0 ? anchor.y - imageBounds.minY : imageBounds.maxY - anchor.y

        if let aspectRatio, aspectRatio > 0 {
            var size = aspectSize(width: abs(point.x - anchor.x), height: abs(point.y - anchor.y), ratio: aspectRatio)
            size = growToMinimum(size, ratio: aspectRatio)
            size = scale(size, toFitWidth: maxWidth, height: maxHeight)
            return makeRect(anchor: anchor, signX: signX, signY: signY, width: size.width, height: size.height)
        }

        let width = min(max(abs(point.x - anchor.x), minimumSize), maxWidth)
        let height = min(max(abs(point.y - anchor.y), minimumSize), maxHeight)
        return makeRect(anchor: anchor, signX: signX, signY: signY, width: width, height: height)
    }

    static func classifyCommit(initial: CGRect, current: CGRect, imageBounds: CGRect, tolerance: CGFloat = 0.001) -> CropCommitAction {
        let bounds = imageBounds.standardized
        let current = clampRect(current, to: bounds)
        if approximatelyEqual(current, initial.standardized, tolerance: tolerance) {
            return .noOp
        }
        if approximatelyEqual(current, bounds, tolerance: tolerance) {
            return .clear
        }
        return .set(current)
    }

    private static func resizeCornerFreeform(rect: CGRect, handle: CropHandle, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let current = rect.standardized
        let imageBounds = bounds.standardized
        let anchor = oppositeCorner(for: handle, in: current)
        let signs = signsForCorner(handle)
        let xRange = range(anchor: anchor.x, sign: signs.x, min: imageBounds.minX, max: imageBounds.maxX)
        let yRange = range(anchor: anchor.y, sign: signs.y, min: imageBounds.minY, max: imageBounds.maxY)
        let x = clamp(point.x, min: xRange.lowerBound, max: xRange.upperBound)
        let y = clamp(point.y, min: yRange.lowerBound, max: yRange.upperBound)
        return CGRect(x: min(anchor.x, x), y: min(anchor.y, y), width: abs(x - anchor.x), height: abs(y - anchor.y))
    }

    private static func resizeCornerWithAspect(rect: CGRect, handle: CropHandle, to point: CGPoint, in bounds: CGRect, ratio: CGFloat) -> CGRect {
        let current = rect.standardized
        let imageBounds = bounds.standardized
        let anchor = oppositeCorner(for: handle, in: current)
        let signs = signsForCorner(handle)
        let maxWidth = signs.x < 0 ? anchor.x - imageBounds.minX : imageBounds.maxX - anchor.x
        let maxHeight = signs.y < 0 ? anchor.y - imageBounds.minY : imageBounds.maxY - anchor.y
        var size = aspectSize(width: abs(point.x - anchor.x), height: abs(point.y - anchor.y), ratio: ratio)
        size = growToMinimum(size, ratio: ratio)
        size = scale(size, toFitWidth: maxWidth, height: maxHeight)
        return makeRect(anchor: anchor, signX: signs.x, signY: signs.y, width: size.width, height: size.height)
    }

    private static func resizeEdgeFreeform(rect: CGRect, handle: CropHandle, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let current = rect.standardized
        let imageBounds = bounds.standardized
        switch handle {
        case .top:
            let y = clamp(point.y, min: imageBounds.minY, max: current.maxY - minimumSize)
            return CGRect(x: current.minX, y: y, width: current.width, height: current.maxY - y)
        case .bottom:
            let maxY = clamp(point.y, min: current.minY + minimumSize, max: imageBounds.maxY)
            return CGRect(x: current.minX, y: current.minY, width: current.width, height: maxY - current.minY)
        case .left:
            let x = clamp(point.x, min: imageBounds.minX, max: current.maxX - minimumSize)
            return CGRect(x: x, y: current.minY, width: current.maxX - x, height: current.height)
        case .right:
            let maxX = clamp(point.x, min: current.minX + minimumSize, max: imageBounds.maxX)
            return CGRect(x: current.minX, y: current.minY, width: maxX - current.minX, height: current.height)
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return current
        }
    }

    private static func resizeEdgeWithAspect(rect: CGRect, handle: CropHandle, to point: CGPoint, in bounds: CGRect, ratio: CGFloat) -> CGRect {
        let current = rect.standardized
        let imageBounds = bounds.standardized
        let minSize = minimumAspectSize(ratio: ratio)

        switch handle {
        case .left, .right:
            let fixedX = handle == .left ? current.maxX : current.minX
            let centerY = current.midY
            let maxWidthByEdge = handle == .left ? fixedX - imageBounds.minX : imageBounds.maxX - fixedX
            let symmetricMaxHeight = max(0, min(centerY - imageBounds.minY, imageBounds.maxY - centerY) * 2)
            let maxWidth = min(maxWidthByEdge, symmetricMaxHeight * ratio)
            let rawWidth = handle == .left ? fixedX - point.x : point.x - fixedX
            let width = clamp(rawWidth, min: minSize.width, max: maxWidth)
            let height = width / ratio
            let x = handle == .left ? fixedX - width : fixedX
            return CGRect(x: x, y: centerY - height / 2, width: width, height: height)
        case .top, .bottom:
            let fixedY = handle == .top ? current.maxY : current.minY
            let centerX = current.midX
            let maxHeightByEdge = handle == .top ? fixedY - imageBounds.minY : imageBounds.maxY - fixedY
            let symmetricMaxWidth = max(0, min(centerX - imageBounds.minX, imageBounds.maxX - centerX) * 2)
            let maxHeight = min(maxHeightByEdge, symmetricMaxWidth / ratio)
            let rawHeight = handle == .top ? fixedY - point.y : point.y - fixedY
            let height = clamp(rawHeight, min: minSize.height, max: maxHeight)
            let width = height * ratio
            return CGRect(x: centerX - width / 2, y: handle == .top ? fixedY - height : fixedY, width: width, height: height)
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return current
        }
    }

    private static func signsForCorner(_ handle: CropHandle) -> (x: CGFloat, y: CGFloat) {
        switch handle {
        case .topLeft:
            return (-1, -1)
        case .topRight:
            return (1, -1)
        case .bottomRight:
            return (1, 1)
        case .bottomLeft:
            return (-1, 1)
        case .top, .right, .bottom, .left:
            return (1, 1)
        }
    }

    private static func oppositeCorner(for handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomLeft:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .top, .right, .bottom, .left:
            return rect.origin
        }
    }

    private static func range(anchor: CGFloat, sign: CGFloat, min: CGFloat, max: CGFloat) -> ClosedRange<CGFloat> {
        if sign < 0 {
            return min...(anchor - minimumSize)
        }
        return (anchor + minimumSize)...max
    }

    private static func aspectSize(width: CGFloat, height: CGFloat, ratio: CGFloat) -> CGSize {
        var width = max(0, width)
        var height = max(0, height)
        if width == 0 && height == 0 {
            return minimumAspectSize(ratio: ratio)
        }
        if height == 0 {
            height = width / ratio
        } else if width == 0 {
            width = height * ratio
        } else if width / height > ratio {
            width = height * ratio
        } else {
            height = width / ratio
        }
        return CGSize(width: width, height: height)
    }

    private static func growToMinimum(_ size: CGSize, ratio: CGFloat) -> CGSize {
        let minimum = minimumAspectSize(ratio: ratio)
        if size.width >= minimum.width && size.height >= minimum.height {
            return size
        }
        return minimum
    }

    private static func minimumAspectSize(ratio: CGFloat) -> CGSize {
        CGSize(width: max(minimumSize, minimumSize * ratio), height: max(minimumSize, minimumSize / ratio))
    }

    private static func scale(_ size: CGSize, toFitWidth maxWidth: CGFloat, height maxHeight: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: size.width * max(0, scale), height: size.height * max(0, scale))
    }

    private static func makeRect(anchor: CGPoint, signX: CGFloat, signY: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        let x = signX < 0 ? anchor.x - width : anchor.x
        let y = signY < 0 ? anchor.y - height : anchor.y
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func centeredRect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private static func preferredSign(delta: CGFloat, negativeSpace: CGFloat, positiveSpace: CGFloat) -> CGFloat {
        if delta < 0 { return -1 }
        if delta > 0 { return 1 }
        return positiveSpace >= negativeSpace ? 1 : -1
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        guard minimum <= maximum else { return minimum }
        return Swift.max(minimum, Swift.min(maximum, value))
    }
}
