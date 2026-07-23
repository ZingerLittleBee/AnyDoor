import AppKit
import ImageIO

/// 190pt card on a 2x display ≈ 380px; round up for headroom.
private let fileThumbnailMaxPixel = 384

/// Cheap, cached, downsampled file thumbnails (clipboard cards, the
/// conversion basket). Decoding the full-resolution
/// image (as `NSImage(contentsOf:)` + scaledToFill does) is expensive when many
/// image/file cards render at once — it stutters the wall's slide-in animation.
/// ImageIO decodes a downsampled thumbnail directly; the decode runs off the
/// main thread and results are cached by path so re-renders and repeated
/// animation frames cost nothing.
///
/// Mirrors `AppIconCache`: a `@MainActor` cache whose dictionaries are only ever
/// touched on the main actor (so they need no lock); only the disk decode is
/// offloaded.
@MainActor
public enum FileThumbnailCache {
    private static var cache: [String: NSImage] = [:]
    private static var inflight: [String: Task<SendableImage?, Never>] = [:]

    /// Carries the non-Sendable `NSImage` produced off-main back to the main
    /// actor. `@unchecked` is sound because the image is freshly created in the
    /// detached task and never mutated afterwards — only read while drawing.
    private struct SendableImage: @unchecked Sendable {
        let image: NSImage
    }

    /// Synchronous, cache-only lookup. Returns nil on a miss without touching
    /// disk, so a card can render a warm thumbnail with no async hop (no flash).
    public static func cached(at url: URL) -> NSImage? {
        cache[url.path]
    }

    /// Returns the downsampled thumbnail for `url`, decoding it on a background
    /// task on a cache miss (ImageIO is not MainActor-isolated, so it never
    /// blocks scrolling). Concurrent requests for the same path share one decode.
    public static func thumbnail(at url: URL) async -> NSImage? {
        let key = url.path
        if let hit = cache[key] { return hit }

        let task: Task<SendableImage?, Never>
        if let existing = inflight[key] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) { decode(url) }
            inflight[key] = task
        }

        let image = await task.value?.image
        inflight[key] = nil
        if let image { cache[key] = image }
        return image
    }

    /// Off-main ImageIO downsample. `nonisolated` so it runs on the detached task.
    private nonisolated static func decode(_ url: URL) -> SendableImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: fileThumbnailMaxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return SendableImage(image: NSImage(cgImage: cgImage, size: .zero))
    }
}
