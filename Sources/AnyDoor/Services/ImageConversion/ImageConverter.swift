import Foundation
import ImageIO

enum ImageConversionError: Error, Sendable {
    case unreadableSource(URL)
    case destinationUnavailable(ImageConversionFormat)
    case encodingFailed(URL)
}

struct ImageConverter: Sendable {
    static let defaultQuality = 0.85
    private static let iconMaxPixel = 256

    func convertFile(
        at sourceURL: URL,
        to outputURL: URL,
        format: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality
    ) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageConversionError.unreadableSource(sourceURL)
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            format.typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ImageConversionError.destinationUnavailable(format)
        }

        let properties = destinationProperties(format: format, quality: quality)
        if format == .ico {
            guard let icon = makeIconImage(from: source) else {
                throw ImageConversionError.unreadableSource(sourceURL)
            }
            CGImageDestinationAddImage(destination, icon, properties as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ImageConversionError.encodingFailed(outputURL)
        }
    }

    static func canDecodeFile(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func isImageFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    private func destinationProperties(format: ImageConversionFormat, quality: Double) -> [CFString: Any] {
        switch format {
        case .jpeg, .heic, .avif:
            return [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)]
        case .png, .tiff, .gif, .bmp, .pdf, .ico:
            return [:]
        }
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
