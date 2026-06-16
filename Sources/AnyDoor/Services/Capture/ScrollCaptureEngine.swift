import CoreGraphics

/// Pure pixel helpers for scrolling capture: per-row fingerprints and top-to-bottom
/// compositing. (The live capture loop now lives in `ScrollCaptureSession` +
/// `ScrollStitchAccumulator`; these synchronous helpers are shared by both and the
/// unit tests.)
enum ScrollCaptureEngine {
    /// Top-to-bottom per-row fingerprints of `image` (RGBA8, one FNV-1a hash/row).
    nonisolated static func rowSignatures(of image: CGImage) -> [ScrollStitch.RowSig]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bpr = w * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        let drew: Bool = data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        // Fingerprint each row from a fixed budget of evenly-spaced pixels rather
        // than every byte. Hashing a full Retina-width row (~3000 px × 4 B) per
        // frame is needlessly expensive — and pathologically slow in unoptimized
        // debug builds — while ~`maxSamples` columns spread across the width still
        // fingerprint a row reliably for stitch alignment. The stride is derived
        // from the width, so identical rows always hash identically and the sampled
        // columns line up across frames.
        let maxSamples = 256
        let step = max(1, w / maxSamples)
        var sigs = [ScrollStitch.RowSig](repeating: 0, count: h)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            // A CGBitmapContext stores its rows top-to-bottom in memory, so buffer
            // row `r` is already the image's top-to-bottom row `r`.
            for r in 0..<h {
                let rowBase = base + r * bpr
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a, folded per RGBA pixel.
                var x = 0
                while x < w {
                    hash ^= UInt64(rowBase.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self))
                    hash = hash &* 0x0000_0100_0000_01b3
                    x += step
                }
                sigs[r] = hash
            }
        }
        return sigs
    }

    /// Stacks pixel slices top-to-bottom into one tall image.
    nonisolated static func composite(slices: [(image: CGImage, height: Int)]) -> CGImage? {
        guard let width = slices.first?.image.width, width > 0 else { return nil }
        let totalH = slices.reduce(0) { $0 + $1.height }
        guard totalH > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: width, height: totalH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var fromTop = 0
        for s in slices {
            // Bottom-left origin: a slice whose top sits `fromTop` below the canvas
            // top is drawn at y = totalH - fromTop - sliceHeight.
            let y = totalH - fromTop - s.height
            ctx.draw(s.image, in: CGRect(x: 0, y: y, width: width, height: s.height))
            fromTop += s.height
        }
        return ctx.makeImage()
    }
}
