import Foundation
import ImageIO

enum ImageConversionError: Error, Sendable {
    case unreadableSource(URL)
    case destinationUnavailable(ImageConversionFormat)
    case encodingFailed(URL)
}

public struct ImageConverter: Sendable {
    public init() {}

    public static let defaultQuality = 0.85
    private static let iconMaxPixel = 256

    @discardableResult
    func convertFile(
        at sourceURL: URL,
        to outputURL: URL,
        format: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality
    ) throws -> CommittedOutput {
        let data = try candidateData(fileAt: sourceURL, format: format, quality: quality)
        return try commit(data, toRequestedURL: outputURL)
    }

    /// Converts an in-memory bitmap (e.g. a pasted screenshot) to `outputURL`.
    @discardableResult
    public func convert(
        data: Data,
        to outputURL: URL,
        format: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality
    ) throws -> CommittedOutput {
        let encoded = try candidateData(bitmapData: data, format: format, quality: quality)
        return try commit(encoded, toRequestedURL: outputURL)
    }

    func candidateData(
        fileAt sourceURL: URL,
        format: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageConversionError.unreadableSource(sourceURL)
        }
        return try encode(source: source, format: format, quality: quality, failureURL: sourceURL)
    }

    func candidateData(
        bitmapData: Data,
        format: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality
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

    private func commit(_ data: Data, toRequestedURL outputURL: URL) throws -> CommittedOutput {
        let store = try CandidateArtifactStore()
        let artifact = try store.materialize(data)
        let destination = AtomicOutputWriter.DestinationPolicy(
            directory: outputURL.deletingLastPathComponent(),
            baseName: outputURL.deletingPathExtension().lastPathComponent,
            fileExtension: outputURL.pathExtension
        )
        return try AtomicOutputWriter().commit(artifact, to: destination)
    }

    static func canDecodeFile(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func canDecodeData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
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
