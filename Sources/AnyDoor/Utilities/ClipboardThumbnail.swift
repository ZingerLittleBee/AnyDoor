import AppKit
import ImageIO

/// Cheap, cached thumbnails for clipboard cards. Decoding the full-resolution
/// image (as `NSImage(contentsOf:)` + scaledToFill does) is expensive when many
/// image/file cards render at once — it stutters the wall's slide-in animation.
/// ImageIO decodes a downsampled thumbnail directly, and results are cached by
/// path so re-renders and repeated animation frames cost nothing.
@MainActor
enum ClipboardThumbnail {
    private static var cache: [String: NSImage] = [:]
    /// 190pt card on a 2x display ≈ 380px; round up for headroom.
    private static let maxPixel = 384

    static func image(at url: URL) -> NSImage? {
        let key = url.path
        if let cached = cache[key] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache[key] = image
        return image
    }
}
