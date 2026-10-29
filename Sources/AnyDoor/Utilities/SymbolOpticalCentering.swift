import AppKit
import SwiftUI

/// Corrects the sub-point misalignment of SF Symbol glyphs inside fixed badges.
///
/// An `Image(systemName:)` sized via `.font` is laid out by its font-metric
/// bounds, and for some symbols (e.g. `clipboard.fill`) the drawn ink sits
/// visibly off the center of those bounds — centering the image in a square
/// badge then renders the glyph ~1pt low. This measures the ink once per
/// (symbol, point size) through `ImageRenderer` (the same rendering path
/// SwiftUI uses on screen) and returns the counter-offset that centers the ink
/// itself.
///
/// The center used is halfway between the ink's bounding box and its center of
/// mass. Pure box centering leaves lopsided symbols looking off: the tray of
/// `tray.and.arrow.down` sits low under its arrow, and the head of `pin` sits
/// high above its needle. Pure mass centering overshoots in the other
/// direction.
@MainActor
enum SymbolOpticalCentering {
    /// The measured ink of one symbol at one point size: the counter-offset
    /// that centers it optically, and its bounding-box size.
    private struct Ink {
        let offset: CGSize
        let size: CGSize
    }

    private static var cache: [String: Ink] = [:]

    static func correction(symbol: String, pointSize: CGFloat) -> CGSize {
        ink(symbol: symbol, pointSize: pointSize).offset
    }

    /// The point size, at most `pointSize`, that evens out how large `symbol`
    /// reads inside a fixed tile. SF Symbols are balanced against text, not
    /// against a square tile, so at one point size a tall clipboard or a wide
    /// pair of windows looks a size larger than a square grid beside it.
    static func balancedPointSize(symbol: String, pointSize: CGFloat, side: CGFloat, maxSide: CGFloat) -> CGFloat {
        let size = ink(symbol: symbol, pointSize: pointSize).size
        let scale = balancedScale(inkSize: size, side: side, maxSide: maxSide)
        // Half-point steps keep the per-size measurement cache small.
        return (pointSize * scale * 2).rounded() / 2
    }

    /// The scale for an ink box of `inkSize` that goes halfway (geometrically)
    /// toward the area of a `side`-point square, then far enough to keep the
    /// longer edge within `maxSide`. It only ever shrinks. Going all the way
    /// overcorrects: a bounding box overstates the weight of open or diagonal
    /// shapes like `hammer` or `link`, which would end up looking too small.
    nonisolated static func balancedScale(inkSize: CGSize, side: CGFloat, maxSide: CGFloat) -> CGFloat {
        guard inkSize.width > 0, inkSize.height > 0 else { return 1 }
        let areaScale = (side / (inkSize.width * inkSize.height).squareRoot()).squareRoot()
        let edgeScale = maxSide / max(inkSize.width, inkSize.height)
        return min(areaScale, edgeScale, 1)
    }

    private static func ink(symbol: String, pointSize: CGFloat) -> Ink {
        let key = "\(symbol)@\(pointSize)"
        if let hit = cache[key] { return hit }
        let ink = measure(symbol: symbol, pointSize: pointSize)
        cache[key] = ink
        return ink
    }

    private static func measure(symbol: String, pointSize: CGFloat) -> Ink {
        let none = Ink(offset: .zero, size: .zero)
        let scale: CGFloat = 4
        let renderer = ImageRenderer(content: Image(systemName: symbol).font(.system(size: pointSize)))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return none }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return none }
        // Redraw into a known RGBA8 layout so the alpha scan below is
        // independent of whatever pixel format ImageRenderer produced.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { return none }
        let px = buf.assumingMemoryBound(to: UInt8.self)
        var minX = w, maxX = -1, minY = h, maxY = -1
        var mass = 0, massX = 0, massY = 0
        for y in 0..<h {
            for x in 0..<w {
                let alpha = Int(px[(y * w + x) * 4 + 3])
                mass += alpha
                massX += alpha * (2 * x + 1)
                massY += alpha * (2 * y + 1)
                guard alpha > 16 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return none }
        // Both centers are kept doubled until here to stay in integers.
        let inkCenterX = (CGFloat(minX + maxX + 1) + CGFloat(massX) / CGFloat(mass)) / 4
        let inkCenterY = (CGFloat(minY + maxY + 1) + CGFloat(massY) / CGFloat(mass)) / 4
        let dx = (CGFloat(w) / 2 - inkCenterX) / scale
        let dy = (CGFloat(h) / 2 - inkCenterY) / scale
        // Snap to half points so the nudge stays pixel-aligned on 2x displays.
        return Ink(
            offset: CGSize(width: (dx * 2).rounded() / 2, height: (dy * 2).rounded() / 2),
            size: CGSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        )
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
