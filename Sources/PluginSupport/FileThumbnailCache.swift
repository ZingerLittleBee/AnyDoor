import AppKit
import ImageIO

private enum FileThumbnailRequest: Hashable, Sendable {
    case maxPixel(Int)
    case fill(width: Int, height: Int)

    var cacheSuffix: String {
        switch self {
        case .maxPixel(let value):
            "max:\(value)"
        case .fill(let width, let height):
            "fill:\(width)x\(height)"
        }
    }
}

enum FileThumbnailSizing {
    /// Prevent pathological image aspect ratios from forcing an enormous decode.
    /// A 4096px long edge covers the card at 2x for ratios well beyond 32:9.
    static let maximumFillMaxPixel = 4096

    /// ImageIO constrains the decoded image's longest edge. Resolve that budget
    /// from both aspect ratios so a `scaledToFill` consumer gets enough pixels
    /// along its constrained axis instead of upscaling a fixed-size thumbnail.
    static func maxPixel(
        sourcePixelSize: CGSize?,
        filling targetPixelSize: CGSize,
        limit: Int = maximumFillMaxPixel
    ) -> Int {
        let targetWidth = max(targetPixelSize.width, 1)
        let targetHeight = max(targetPixelSize.height, 1)
        let fallback = Int(ceil(max(targetWidth, targetHeight)))
        guard let sourcePixelSize,
              sourcePixelSize.width > 0,
              sourcePixelSize.height > 0 else {
            return min(max(limit, 1), fallback)
        }

        let sourceAspect = sourcePixelSize.width / sourcePixelSize.height
        let targetAspect = targetWidth / targetHeight
        let requiredLongEdge = sourceAspect >= targetAspect
            ? targetHeight * sourceAspect
            : targetWidth / sourceAspect
        return min(max(limit, 1), Int(ceil(max(requiredLongEdge, CGFloat(fallback)))))
    }
}

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
        cached(at: url, request: .maxPixel(max(maxPixel, 1)))
    }

    /// Cache-only lookup for a `scaledToFill` consumer. The target is expressed
    /// in backing pixels, not points.
    public static func cached(at url: URL, filling targetPixelSize: CGSize) -> NSImage? {
        cached(at: url, request: fillRequest(targetPixelSize))
    }

    /// Returns the downsampled thumbnail for `url`, decoding it on a background
    /// task on a cache miss (ImageIO is not MainActor-isolated, so it never
    /// blocks scrolling). Concurrent requests for the same path share one decode.
    public static func thumbnail(at url: URL, maxPixel: Int = FileThumbnailCache.defaultMaxPixel) async -> NSImage? {
        await thumbnail(at: url, request: .maxPixel(max(maxPixel, 1)))
    }

    /// Returns a thumbnail large enough to fill `targetPixelSize` without
    /// upscaling for practical image aspect ratios. Source metadata is read on
    /// the decode task, and pathological long edges are capped at 4096px.
    public static func thumbnail(at url: URL, filling targetPixelSize: CGSize) async -> NSImage? {
        await thumbnail(at: url, request: fillRequest(targetPixelSize))
    }

    private static func cached(at url: URL, request: FileThumbnailRequest) -> NSImage? {
        cache.object(forKey: key(url, request) as NSString)
    }

    private static func thumbnail(at url: URL, request: FileThumbnailRequest) async -> NSImage? {
        let key = key(url, request)
        if let hit = cache.object(forKey: key as NSString) { return hit }

        let task: Task<SendableImage?, Never>
        if let existing = inflight[key] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) { decode(url, request: request) }
            inflight[key] = task
        }

        let decoded = await task.value
        inflight[key] = nil
        if let decoded {
            cache.setObject(decoded.image, forKey: key as NSString, cost: decoded.cost)
        }
        return decoded?.image
    }

    private static func fillRequest(_ targetPixelSize: CGSize) -> FileThumbnailRequest {
        .fill(
            width: max(Int(ceil(targetPixelSize.width)), 1),
            height: max(Int(ceil(targetPixelSize.height)), 1)
        )
    }

    private static func key(_ url: URL, _ request: FileThumbnailRequest) -> String {
        "\(url.path)#\(request.cacheSuffix)"
    }

    /// Off-main ImageIO downsample. `nonisolated` so it runs on the detached task.
    private nonisolated static func decode(
        _ url: URL,
        request: FileThumbnailRequest
    ) -> SendableImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixel: Int
        switch request {
        case .maxPixel(let value):
            maxPixel = value
        case .fill(let width, let height):
            maxPixel = FileThumbnailSizing.maxPixel(
                sourcePixelSize: orientedPixelSize(of: source),
                filling: CGSize(width: width, height: height)
            )
        }
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

    private nonisolated static func orientedPixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0,
              height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}
