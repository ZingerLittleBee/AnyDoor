import Foundation

/// The panel can resize freely; the image itself always remains aspect-fit.
/// A small amount of letterboxing keeps controls usable even for narrow captures.
enum PinnedImageLayout {
    static let minimumSize = CGSize(width: 180, height: 100)
    static let initialMaximumDimension: CGFloat = 360
    static let resizeBorderWidth: CGFloat = 8
    static let toolbarSize = CGSize(width: 156, height: 32)
    static let toolbarInset: CGFloat = 12

    static func initialSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return minimumSize }
        let scale = min(1, initialMaximumDimension / max(imageSize.width, imageSize.height))
        return CGSize(
            width: max(minimumSize.width, imageSize.width * scale),
            height: max(minimumSize.height, imageSize.height * scale)
        )
    }

    /// Nonoverlapping hit regions covering the inside border (y-up). Corners
    /// come first so cursor registration and mouse hit-testing share one order.
    static func resizeRegions(in bounds: CGRect) -> [(SelectionHandle, CGRect)] {
        guard !bounds.isEmpty else { return [] }
        let xInset = min(resizeBorderWidth, bounds.width / 2)
        let yInset = min(resizeBorderWidth, bounds.height / 2)
        let innerWidth = bounds.width - 2 * xInset
        let innerHeight = bounds.height - 2 * yInset
        return [
            (.topLeft, CGRect(x: bounds.minX, y: bounds.maxY - yInset, width: xInset, height: yInset)),
            (.topRight, CGRect(x: bounds.maxX - xInset, y: bounds.maxY - yInset, width: xInset, height: yInset)),
            (.bottomRight, CGRect(x: bounds.maxX - xInset, y: bounds.minY, width: xInset, height: yInset)),
            (.bottomLeft, CGRect(x: bounds.minX, y: bounds.minY, width: xInset, height: yInset)),
            (.top, CGRect(x: bounds.minX + xInset, y: bounds.maxY - yInset, width: innerWidth, height: yInset)),
            (.right, CGRect(x: bounds.maxX - xInset, y: bounds.minY + yInset, width: xInset, height: innerHeight)),
            (.bottom, CGRect(x: bounds.minX + xInset, y: bounds.minY, width: innerWidth, height: yInset)),
            (.left, CGRect(x: bounds.minX, y: bounds.minY + yInset, width: xInset, height: innerHeight)),
        ]
    }

    static func resizeHandle(at point: CGPoint, in bounds: CGRect) -> SelectionHandle? {
        resizeRegions(in: bounds).first { $0.1.contains(point) }?.0
    }

    /// Small visual grips stay inside the existing resize hit regions. Corner
    /// grips sit toward the interior so the rounded image clip keeps them visible.
    static func resizeGripFrames(in bounds: CGRect) -> [(SelectionHandle, CGRect)] {
        resizeRegions(in: bounds).map { handle, region in
            let size: CGSize
            switch handle {
            case .top, .bottom: size = CGSize(width: min(24, region.width), height: min(4, region.height))
            case .left, .right: size = CGSize(width: min(4, region.width), height: min(24, region.height))
            default: size = CGSize(width: min(5, region.width), height: min(5, region.height))
            }
            var origin = CGPoint(x: region.midX - size.width / 2, y: region.midY - size.height / 2)
            switch handle {
            case .topLeft: origin = CGPoint(x: region.maxX - size.width, y: region.minY)
            case .topRight: origin = region.origin
            case .bottomRight: origin = CGPoint(x: region.minX, y: region.maxY - size.height)
            case .bottomLeft: origin = CGPoint(x: region.maxX - size.width, y: region.maxY - size.height)
            default: break
            }
            return (handle, CGRect(origin: origin, size: size))
        }
    }

    /// Apply the total global mouse delta to the frame captured at mouse-down,
    /// never to the previous drag result. Opposite edges stay anchored, including
    /// when the moving edge crosses them or reaches the hard minimum (y-up).
    static func resizedFrame(_ initialFrame: CGRect, handle: SelectionHandle, delta: CGSize) -> CGRect {
        var x = initialFrame.minX
        var y = initialFrame.minY
        var width = max(minimumSize.width, initialFrame.width)
        var height = max(minimumSize.height, initialFrame.height)

        let movesLeft = handle == .topLeft || handle == .left || handle == .bottomLeft
        let movesRight = handle == .topRight || handle == .right || handle == .bottomRight
        let movesTop = handle == .topLeft || handle == .top || handle == .topRight
        let movesBottom = handle == .bottomLeft || handle == .bottom || handle == .bottomRight

        if movesLeft {
            width = max(minimumSize.width, initialFrame.width - delta.width)
            x = initialFrame.maxX - width
        }
        if movesRight {
            width = max(minimumSize.width, initialFrame.width + delta.width)
        }
        if movesBottom {
            height = max(minimumSize.height, initialFrame.height - delta.height)
            y = initialFrame.maxY - height
        }
        if movesTop {
            height = max(minimumSize.height, initialFrame.height + delta.height)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The toolbar is a fixed-size child at the image frame's top-right corner.
    static func toolbarFrame(for imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.maxX - toolbarInset - toolbarSize.width,
            y: imageFrame.maxY - toolbarInset - toolbarSize.height,
            width: toolbarSize.width,
            height: toolbarSize.height
        )
    }
}
