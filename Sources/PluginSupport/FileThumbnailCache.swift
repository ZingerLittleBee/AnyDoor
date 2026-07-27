import AppKit
import ImageIO

/// Cheap, cached, downsampled file thumbnails (clipboard cards, the
/// conversion basket). Decoding the full-resolution
/// image (as `NSImage(contentsOf:)` + scaledToFill does) is expensive when many
/// image/file cards render at once — it stutters the wall's slide-in animation.
/// ImageIO decodes a downsampled thumbnail directly; the decode runs off the
/// main thread and results are cached by path so re-renders and repeated
/// animation frames cost nothing.
///
/// The pixel budget is per call: a caller that renders bigger (the clipboard
/// wall's cards crop `scaledToFill`, so the source needs more pixels than the
/// card is wide) asks for more, and each budget is cached separately — a
/// thumbnail decoded for a small row must never be stretched into a large one.
///
/// Backed by `NSCache`, so the (now larger) images are evicted under memory
/// pressure or once the cost limit is hit instead of growing without bound.
@MainActor
public enum FileThumbnailCache {
    /// Default budget: a ~190pt list thumbnail on a 2x display ≈ 380px.
    public nonisolated static let defaultMaxPixel = 384

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024   // bytes of decoded bitmap
        return cache
    }()
    private static var inflight: [String: Task<SendableImage?, Never>] = [:]

    /// Carries the non-Sendable `NSImage` produced off-main back to the main
    /// actor. `@unchecked` is sound because the image is freshly created in the
    /// detached task and never mutated afterwards — only read while drawing.
    private struct SendableImage: @unchecked Sendable {
        let image: NSImage
        let cost: Int
    }

    /// Synchronous, cache-only lookup. Returns nil on a miss without touching
    /// disk, so a card can render a warm thumbnail with no async hop (no flash).
    public static func cached(at url: URL, maxPixel: Int = FileThumbnailCache.defaultMaxPixel) -> NSImage? {
        cache.object(forKey: key(url, maxPixel) as NSString)
    }

    /// Returns the downsampled thumbnail for `url`, decoding it on a background
    /// task on a cache miss (ImageIO is not MainActor-isolated, so it never
    /// blocks scrolling). Concurrent requests for the same path share one decode.
    public static func thumbnail(at url: URL, maxPixel: Int = FileThumbnailCache.defaultMaxPixel) async -> NSImage? {
        let key = key(url, maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit }

        let task: Task<SendableImage?, Never>
        if let existing = inflight[key] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) { decode(url, maxPixel: maxPixel) }
            inflight[key] = task
        }

        let decoded = await task.value
        inflight[key] = nil
        if let decoded {
            cache.setObject(decoded.image, forKey: key as NSString, cost: decoded.cost)
        }
        return decoded?.image
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> String {
        "\(url.path)#\(maxPixel)"
    }

    /// Off-main ImageIO downsample. `nonisolated` so it runs on the detached task.
    private nonisolated static func decode(_ url: URL, maxPixel: Int) -> SendableImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return SendableImage(
            image: NSImage(cgImage: cgImage, size: .zero),
            cost: cgImage.height * cgImage.bytesPerRow
        )
    }
}
