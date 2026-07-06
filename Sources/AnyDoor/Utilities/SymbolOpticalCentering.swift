import AppKit
import SwiftUI

/// Corrects the sub-point misalignment of SF Symbol glyphs inside fixed badges.
///
/// An `Image(systemName:)` sized via `.font` is laid out by its font-metric
/// bounds, and for some symbols (e.g. `clipboard.fill`) the drawn ink sits
/// visibly off the center of those bounds — centering the image in a square
/// badge then renders the glyph ~1pt low. This measures the ink's bounding box
/// once per (symbol, point size) through `ImageRenderer` (the same rendering
/// path SwiftUI uses on screen) and returns the counter-offset that centers
/// the ink itself.
@MainActor
enum SymbolOpticalCentering {
    private static var cache: [String: CGSize] = [:]

    static func correction(symbol: String, pointSize: CGFloat) -> CGSize {
        let key = "\(symbol)@\(pointSize)"
        if let hit = cache[key] { return hit }
        let offset = measure(symbol: symbol, pointSize: pointSize)
        cache[key] = offset
        return offset
    }

    private static func measure(symbol: String, pointSize: CGFloat) -> CGSize {
        let scale: CGFloat = 4
        let renderer = ImageRenderer(content: Image(systemName: symbol).font(.system(size: pointSize)))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return .zero }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return .zero }
        // Redraw into a known RGBA8 layout so the alpha scan below is
        // independent of whatever pixel format ImageRenderer produced.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { return .zero }
        let px = buf.assumingMemoryBound(to: UInt8.self)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return .zero }
        let inkCenterX = CGFloat(minX + maxX + 1) / 2
        let inkCenterY = CGFloat(minY + maxY + 1) / 2
        let dx = (CGFloat(w) / 2 - inkCenterX) / scale
        let dy = (CGFloat(h) / 2 - inkCenterY) / scale
        // Snap to half points so the nudge stays pixel-aligned on 2x displays.
        return CGSize(width: (dx * 2).rounded() / 2, height: (dy * 2).rounded() / 2)
    }
}

extension View {
    /// Nudges a font-sized SF Symbol so its ink (not its font-metric bounds)
    /// lands centered when this view is centered inside a fixed frame.
    @MainActor
    func opticallyCentered(symbol: String, pointSize: CGFloat) -> some View {
        offset(SymbolOpticalCentering.correction(symbol: symbol, pointSize: pointSize))
    }
}
