import AVFoundation
import AppKit

/// First-frame covers are derived in memory only, never persisted as plaintext.
@MainActor
enum VideoThumbnailCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func thumbnail(at url: URL, maxPixel: Int) async -> CGImage? {
        guard !Task.isCancelled, url.isFileURL else { return nil }
        let budget = min(max(maxPixel, 1), 1024)
        guard let key = await cacheKey(url, maxPixel: budget), !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: key as NSString) { return image }
        guard let image = await firstFrame(url, maxPixel: budget), !Task.isCancelled else { return nil }
        cache.setObject(image, forKey: key as NSString, cost: image.height * image.bytesPerRow)
        return image
    }

    @concurrent
    private static func cacheKey(_ url: URL, maxPixel: Int) async -> String? {
        var fileURL = url
        fileURL.removeAllCachedResourceValues()
        guard let values = try? fileURL.resourceValues(forKeys: [
            .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
        ]), values.isRegularFile == true else { return nil }
        return "\(url.path)#\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)#\(values.creationDate?.timeIntervalSince1970 ?? 0)#\(values.fileSize ?? 0)#\(maxPixel)"
    }

    @concurrent
    private static func firstFrame(_ url: URL, maxPixel: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let request = FrameRequest()
        return await withTaskCancellationHandler {
            await request.image(at: url, maxPixel: maxPixel)
        } onCancel: {
            Task { await request.cancel() }
        }
    }

    /// AVAssetImageGenerator is not Sendable. Keep configuration, request
    /// submission, and cancellation on one actor; only the immutable image
    /// crosses back to the UI. The callback API avoids sending the generator
    /// to a separate executor through its async convenience method.
    private actor FrameRequest {
        private var generator: AVAssetImageGenerator?
        private var isCancelled = false

        func image(at url: URL, maxPixel: Int) async -> CGImage? {
            guard !isCancelled, !Task.isCancelled else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            self.generator = generator
            defer { self.generator = nil }
            return await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                    continuation.resume(returning: image)
                }
            }
        }

        func cancel() {
            isCancelled = true
            generator?.cancelAllCGImageGeneration()
        }
    }
}
