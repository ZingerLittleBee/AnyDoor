import CoreGraphics
import Foundation
import ImageIO

/// Runtime-proven encoder capabilities.
///
/// JPEG is known non-alpha; HEIC and AVIF alpha support is probed once per
/// process with a tiny encode/decode round trip and cached, because Apple
/// documents no cross-version alpha guarantee. Capability is part of the
/// frozen configuration contract: when a real candidate contradicts the
/// cache, the engine calls `invalidate()` and reruns preflight instead of
/// silently compositing.
enum ImageIOCapabilityCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var alphaByFormat: [ImageConversionFormat: Bool] = [:]

    /// Whether encoding to `format` can preserve source alpha on this runtime.
    static func targetPreservesAlpha(_ format: ImageConversionFormat) -> Bool {
        switch format {
        case .png, .tiff, .gif, .ico:
            return true
        // WebP is encoded by the bundled libwebp, whose alpha support does
        // not vary with the OS encoder set.
        case .webp:
            return true
        case .jpeg, .bmp, .pdf:
            return false
        case .heic, .avif:
            return probedAlpha(format)
        }
    }

    /// The `capabilityChanged` path: forget every probe so the next use
    /// re-proves capability on the live runtime.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        alphaByFormat.removeAll()
    }

    private static func probedAlpha(_ format: ImageConversionFormat) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = alphaByFormat[format] { return cached }
        let survived = alphaRoundTripSurvives(format)
        alphaByFormat[format] = survived
        return survived
    }

    /// Encode a tiny image whose left half is 50% translucent, decode it
    /// back, and verify translucency survived. What the runtime proves wins
    /// over what the format name promises.
    private static func alphaRoundTripSurvives(_ format: ImageConversionFormat) -> Bool {
        guard ImageConversionFormat.availableTargets().contains(format),
              let probe = makeProbeImage() else { return false }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, format.typeIdentifier as CFString, 1, nil
        ) else { return false }
        let properties = [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary
        CGImageDestinationAddImage(destination, probe, properties)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(encoded, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }

        return decodedTranslucencySurvives(decoded)
    }

    private static let probeSide = 16

    private static func makeProbeImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: probeSide,
            height: probeSide,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: probeSide, height: probeSide))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: probeSide / 2, height: probeSide))
        return context.makeImage()
    }

    private static func decodedTranslucencySurvives(_ decoded: CGImage) -> Bool {
        let width = decoded.width
        let height = decoded.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        // The first pixel sits in the 50%-alpha half. A flattening encoder
        // yields 255 there; a generous band tolerates lossy drift.
        let alpha = Int(pixels[3])
        return alpha > 32 && alpha < 224
    }
}
