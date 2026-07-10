import CoreGraphics
import Foundation
import ImageIO

/// Encodes measured candidates for one source image.
///
/// The source is decoded once; every candidate re-renders from that original
/// decoded image (never from a previous resized candidate) into an in-memory
/// destination. Outputs are rebuilt from pixels plus explicit display
/// properties, so ancillary metadata is absent by construction; orientation
/// is re-attached and a same-size candidate re-attaches a supported HDR gain
/// map. Not Sendable — instances live inside the engine actor.
final class ImageIOCandidateEncoder {
    enum EncoderError: Error {
        case undecodable
        case encoderUnavailable(ImageConversionFormat)
        case encodingFailed
    }

    private let source: CGImageSource
    private let originalImage: CGImage
    private let orientation: UInt32?
    private let sourceHasAlpha: Bool

    /// UTI of the source container (e.g. `public.jpeg`), for same-format
    /// pass-through eligibility.
    let sourceTypeIdentifier: String?
    var originalDimensions: PixelDimensions {
        PixelDimensions(width: originalImage.width, height: originalImage.height)
    }

    init(input: ImageConversionInput) throws {
        let created: CGImageSource? = switch input {
        case .file(let url): CGImageSourceCreateWithURL(url as CFURL, nil)
        case .bitmap(let data): CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let created,
              CGImageSourceGetCount(created) >= 1,
              let image = CGImageSourceCreateImageAtIndex(created, 0, nil) else {
            throw EncoderError.undecodable
        }
        source = created
        originalImage = image
        sourceTypeIdentifier = CGImageSourceGetType(created) as String?

        let properties = CGImageSourceCopyPropertiesAtIndex(created, 0, nil) as? [CFString: Any]
        orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            ?? (properties?[kCGImagePropertyOrientation] as? Int).map(UInt32.init)
        sourceHasAlpha = properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    struct EncodeSpec: Hashable, Sendable {
        var format: ImageConversionFormat
        /// Whole-percent encoder quality (1–100).
        var quality: Int
        /// Target pixel size; smaller sizes resample from the original.
        var dimensions: PixelDimensions
        /// Explicit composite color (`#RRGGBB`) when the target cannot encode
        /// this source's alpha. Never rely on Image I/O's implicit white.
        var transparencyBackgroundHex: String?
    }

    func encode(_ spec: EncodeSpec) throws -> Data {
        let pixels = try renderPixels(
            dimensions: spec.dimensions,
            backgroundHex: spec.transparencyBackgroundHex
        )
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, spec.format.typeIdentifier as CFString, 1, nil
        ) else {
            throw EncoderError.encoderUnavailable(spec.format)
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Double(spec.quality) / 100.0,
        ]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)

        // A same-size candidate may retain a supported HDR gain map; a resized
        // one cannot (the map's dimensions no longer match). A destination
        // that ignores the auxiliary data yields an SDR result, which the
        // audit reports and the record stores as hdrToSDR.
        if spec.dimensions == originalDimensions,
           let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
               source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
           ) {
            CGImageDestinationAddAuxiliaryDataInfo(
                destination, kCGImageAuxiliaryDataTypeHDRGainMap, gainMap
            )
        }

        guard CGImageDestinationFinalize(destination) else {
            throw EncoderError.encodingFailed
        }
        return encoded as Data
    }

    /// The lossless container rewrite with the Target Size metadata policy.
    /// Returns nil when Image I/O rejects the operation for this source; a
    /// returned result still has to pass the full audit and the byte limit.
    func losslessPassThrough(as format: ImageConversionFormat) -> Data? {
        guard sourceTypeIdentifier == format.typeIdentifier else { return nil }
        let rewritten = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            rewritten, format.typeIdentifier as CFString, 1, nil
        ) else { return nil }
        // CGImageDestinationCopyImageSource finalizes internally.
        guard CGImageDestinationCopyImageSource(
            destination, source, TargetMetadataPolicy.passThroughOptions(), nil
        ) else { return nil }
        return rewritten as Data
    }

    // MARK: - Pixel rendering

    private func renderPixels(dimensions: PixelDimensions, backgroundHex: String?) throws -> CGImage {
        let needsComposite = backgroundHex != nil && sourceHasAlpha
        let needsResize = dimensions.width != originalImage.width
            || dimensions.height != originalImage.height
        guard needsComposite || needsResize else { return originalImage }

        let colorSpace = originalImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alphaInfo: CGImageAlphaInfo = needsComposite ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(
            data: nil,
            width: dimensions.width,
            height: dimensions.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else {
            throw EncoderError.encodingFailed
        }
        context.interpolationQuality = .high

        let rect = CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height)
        if needsComposite, let hex = backgroundHex, let background = Self.color(fromHex: hex) {
            context.setFillColor(background)
            context.fill(rect)
        }
        context.draw(originalImage, in: rect)

        guard let rendered = context.makeImage() else { throw EncoderError.encodingFailed }
        return rendered
    }

    /// `#RRGGBB` → sRGB CGColor. Invalid input returns nil so a caller bug
    /// surfaces as a policy failure instead of a silent white composite.
    static func color(fromHex hex: String) -> CGColor? {
        var value = hex
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
