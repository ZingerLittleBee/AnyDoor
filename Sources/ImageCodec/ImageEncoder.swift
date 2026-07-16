import Foundation
import ImageIO

public enum ImageConversionError: Error, Sendable {
    case unreadableSource(URL)
    case destinationUnavailable(ImageConversionFormat)
    case encodingFailed(URL)
}

/// Pure ImageIO single-image encode: source bytes/file in, encoded bytes out.
/// No file placement — callers own where (and how atomically) the result
/// lands. WebP is not encodable here (ImageIO has no encoder); the bundled
/// libwebp path lives in the Image Conversion plugin's Target Size pipeline.
public struct ImageEncoder: Sendable {
    private static let iconMaxPixel = 256

    public init() {}

    public func encode(
        fileAt sourceURL: URL,
        format: ImageConversionFormat,
        quality: Double
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageConversionError.unreadableSource(sourceURL)
        }
        return try encode(source: source, format: format, quality: quality, failureURL: sourceURL)
    }

    public func encode(
        bitmapData: Data,
        format: ImageConversionFormat,
        quality: Double
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(bitmapData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageConversionError.encodingFailed(URL(fileURLWithPath: "bitmap"))
        }
        return try encode(
            source: source,
            format: format,
            quality: quality,
            failureURL: URL(fileURLWithPath: "bitmap")
        )
    }

    private func encode(
        source: CGImageSource,
        format: ImageConversionFormat,
        quality: Double,
        failureURL: URL
    ) throws -> Data {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            format.typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ImageConversionError.destinationUnavailable(format)
        }

        let properties = destinationProperties(format: format, quality: quality)
        if format == .ico {
            guard let icon = makeIconImage(from: source) else {
                throw ImageConversionError.encodingFailed(failureURL)
            }
            CGImageDestinationAddImage(destination, icon, properties as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ImageConversionError.encodingFailed(failureURL)
        }
        return encoded as Data
    }

    private func destinationProperties(format: ImageConversionFormat, quality: Double) -> [CFString: Any] {
        guard format.isLossy else { return [:] }
        return [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)]
    }

    private func makeIconImage(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.iconMaxPixel,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let side = max(thumbnail.width, thumbnail.height)
        guard side > 0 else { return nil }
        if thumbnail.width == side, thumbnail.height == side {
            return thumbnail
        }
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let x = (side - thumbnail.width) / 2
        let y = (side - thumbnail.height) / 2
        context.draw(
            thumbnail,
            in: CGRect(x: x, y: y, width: thumbnail.width, height: thumbnail.height)
        )
        return context.makeImage()
    }
}
