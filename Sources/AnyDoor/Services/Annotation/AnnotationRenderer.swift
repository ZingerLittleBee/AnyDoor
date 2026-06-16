import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

extension RGBAColor {
    /// AppKit color in sRGB. Kept out of the pure model so the model has no AppKit
    /// dependency.
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

/// Composites an `AnnotationDocument` (base image + element layers + crop) into a
/// final `CGImage`. Drawing happens in a **flipped** `NSGraphicsContext` so element
/// geometry — stored in the base image's top-left pixel space — maps directly, and
/// AppKit text/shapes render upright. Blur / pixelate sample the base via CoreImage.
@MainActor
enum AnnotationRenderer {
    /// Shared CoreImage context (creating one per render is expensive and the
    /// canvas re-renders on every drag frame).
    private static let ciContext = CIContext(options: nil)

    /// Cache of processed blur/pixelate region images, keyed by kind + base image
    /// + region. The canvas re-renders every drag frame, so without this a blur
    /// element re-runs CoreImage over the base on each frame (even when the user
    /// is dragging a *different* element). Pruned to the keys touched by the most
    /// recent render, so it stays bounded: transient drag regions evict next
    /// frame while stable elements stay warm.
    private static var processCache: [ProcessKey: CGImage] = [:]
    private static var touchedProcessKeys: Set<ProcessKey> = []

    /// Renders the document to a `CGImage`. When `applyCrop` is true (the default,
    /// used for export) the crop is applied; the canvas passes false so it can show
    /// the full image with a separate crop overlay while editing. Returns nil only
    /// if a bitmap context cannot be created.
    static func render(_ doc: AnnotationDocument, applyCrop: Bool = true) -> CGImage? {
        let w = doc.baseImage.width
        let h = doc.baseImage.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // Flip the CTM to a top-left origin so it matches the `flipped: true` hint
        // below — like drawing into a flipped NSView. The hint alone does NOT flip
        // the CTM, so without this the base image renders upside down and elements
        // (authored in top-left pixel space) land in bottom-left space.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        let imageRect = CGRect(x: 0, y: 0, width: w, height: h)
        NSImage(cgImage: doc.baseImage, size: imageRect.size).draw(in: imageRect)

        touchedProcessKeys.removeAll(keepingCapacity: true)
        for element in doc.elements {
            draw(element, baseImage: doc.baseImage, imageHeight: h)
        }
        // Drop cache entries not used this render so the cache can't grow without
        // bound across drag frames (each frame's transient blur region is a new key).
        processCache = processCache.filter { touchedProcessKeys.contains($0.key) }

        guard let full = ctx.makeImage() else { return nil }
        if applyCrop, let crop = doc.cropRect, crop.width >= 1, crop.height >= 1 {
            return full.cropping(to: crop) ?? full
        }
        return full
    }

    /// Convenience: the rendered document as an `NSImage` sized to its pixels.
    static func renderImage(_ doc: AnnotationDocument) -> NSImage? {
        guard let cg = render(doc) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Element drawing (flipped, top-left coordinates)

    private static func draw(_ element: AnnotationElement, baseImage: CGImage, imageHeight h: Int) {
        let style = element.style
        let stroke = style.strokeColor.nsColor

        switch element.kind {
        case let .arrow(from, to):
            let path = NSBezierPath()
            path.lineWidth = style.strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: from)
            path.line(to: to)
            let (l, r) = AnnotationGeometry.arrowHead(from: from, to: to, length: max(12, style.strokeWidth * 3.5))
            path.move(to: l)
            path.line(to: to)
            path.line(to: r)
            stroke.setStroke()
            path.stroke()

        case let .line(from, to):
            let path = NSBezierPath()
            path.lineWidth = style.strokeWidth
            path.lineCapStyle = .round
            path.move(to: from)
            path.line(to: to)
            stroke.setStroke()
            path.stroke()

        case let .rectangle(rect):
            let path = NSBezierPath(rect: rect)
            path.lineWidth = style.strokeWidth
            if let fill = style.fillColor?.nsColor { fill.setFill(); path.fill() }
            stroke.setStroke()
            path.stroke()

        case let .ellipse(rect):
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = style.strokeWidth
            if let fill = style.fillColor?.nsColor { fill.setFill(); path.fill() }
            stroke.setStroke()
            path.stroke()

        case let .freehand(points):
            strokePath(points, color: stroke, width: style.strokeWidth)

        case let .highlighter(points):
            strokePath(points, color: stroke.withAlphaComponent(0.35), width: max(16, style.strokeWidth * 4))

        case let .text(string, origin):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: style.fontSize),
                .foregroundColor: stroke,
            ]
            (string as NSString).draw(at: origin, withAttributes: attrs)

        case let .redaction(rect):
            NSColor.black.setFill()
            NSBezierPath(rect: rect).fill()

        case let .blur(rect):
            drawProcessed(.blur, base: baseImage, region: rect, imageHeight: h)

        case let .pixelate(rect):
            drawProcessed(.pixelate, base: baseImage, region: rect, imageHeight: h)

        case let .counter(number, center):
            drawCounter(number, center: center, style: style)
        }
    }

    private static func strokePath(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.move(to: first)
        for p in points.dropFirst() { path.line(to: p) }
        color.setStroke()
        path.stroke()
    }

    private static func drawCounter(_ number: Int, center: CGPoint, style: AnnotationStyle) {
        let r = AnnotationGeometry.counterRadius(for: style)
        let rect = AnnotationGeometry.counterCircleRect(center: center, radius: r)
        style.strokeColor.nsColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: r),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }

    private enum ProcessKind: Hashable { case blur, pixelate }

    /// Cache key: a processed region is fully determined by the filter kind, the
    /// base image, and the region (pixelate's scale derives from the region size).
    private struct ProcessKey: Hashable {
        let kind: ProcessKind
        let baseID: UInt
        let baseW: Int
        let baseH: Int
        let x: Int, y: Int, w: Int, h: Int
    }

    private static func drawProcessed(_ kind: ProcessKind, base: CGImage, region: CGRect, imageHeight h: Int) {
        guard region.width >= 1, region.height >= 1 else { return }
        let key = ProcessKey(
            kind: kind,
            baseID: UInt(bitPattern: Unmanaged.passUnretained(base).toOpaque()),
            baseW: base.width, baseH: base.height,
            x: Int(region.minX.rounded()), y: Int(region.minY.rounded()),
            w: Int(region.width.rounded()), h: Int(region.height.rounded())
        )
        touchedProcessKeys.insert(key)

        let processed: CGImage
        if let cached = processCache[key] {
            processed = cached
        } else if let made = makeProcessed(kind, base: base, region: region, imageHeight: h) {
            processCache[key] = made
            processed = made
        } else {
            return
        }
        NSImage(cgImage: processed, size: region.size).draw(in: region)
    }

    /// Run the CoreImage filter and materialise the region (the costly step).
    /// CoreImage applies a region-of-interest, so only the cropped region is
    /// rendered despite the filter being expressed over the full base.
    private static func makeProcessed(_ kind: ProcessKind, base: CGImage, region: CGRect, imageHeight h: Int) -> CGImage? {
        let ci = CIImage(cgImage: base)
        let filtered: CIImage
        switch kind {
        case .blur:
            filtered = ci.clampedToExtent()
                .applyingGaussianBlur(sigma: 14)
                .cropped(to: ci.extent)
        case .pixelate:
            let f = CIFilter.pixellate()
            f.inputImage = ci
            f.scale = Float(max(8, min(region.width, region.height) / 8))
            // CoreImage is bottom-left; flip the center's y.
            f.center = CGPoint(x: region.midX, y: CGFloat(h) - region.midY)
            filtered = (f.outputImage ?? ci).cropped(to: ci.extent)
        }
        // Region in CoreImage's bottom-left space.
        let ciRect = CGRect(x: region.minX, y: CGFloat(h) - region.maxY, width: region.width, height: region.height)
        return ciContext.createCGImage(filtered, from: ciRect)
    }
}
