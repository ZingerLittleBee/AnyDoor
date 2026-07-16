import Foundation
import ImageCodec
import ImageIO

/// The plugin's file-level conversion front: decode checks plus
/// encode-and-commit, delegating the pure encode to `ImageCodec.ImageEncoder`
/// and committing outputs through the atomic candidate/writer pipeline.
struct ImageConverter: Sendable {
    init() {}

    static let defaultQuality = 0.85

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
    func convert(
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
        try ImageEncoder().encode(fileAt: sourceURL, format: format, quality: quality)
    }

    func candidateData(
        bitmapData: Data,
        format: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality
    ) throws -> Data {
        try ImageEncoder().encode(bitmapData: bitmapData, format: format, quality: quality)
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
}
