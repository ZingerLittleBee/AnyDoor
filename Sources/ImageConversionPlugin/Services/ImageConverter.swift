import Foundation
import ImageCodec
import ImageIO

/// The plugin's file-level conversion front: decode checks plus candidate
/// encoding, delegating the pure encode to `ImageCodec.ImageEncoder`. Callers
/// commit the bytes through the atomic candidate/writer pipeline.
struct ImageConverter: Sendable {
    init() {}

    func candidateData(
        fileAt sourceURL: URL,
        format: ImageConversionFormat,
        quality: Double
    ) throws -> Data {
        try ImageEncoder().encode(fileAt: sourceURL, format: format, quality: quality)
    }

    func candidateData(
        bitmapData: Data,
        format: ImageConversionFormat,
        quality: Double
    ) throws -> Data {
        try ImageEncoder().encode(bitmapData: bitmapData, format: format, quality: quality)
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
}
