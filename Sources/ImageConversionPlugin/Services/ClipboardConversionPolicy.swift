import Foundation
import PluginInterface
import UniformTypeIdentifiers

/// Pure policy for the clipboard-history "Convert Image Format" action: which
/// payloads expose it, which of a file payload's URLs are images, and how a
/// payload loads into basket items. The exposure check is disk-free because it
/// runs at context-menu build time; loading is deferred to the commit.
enum ClipboardConversionPolicy {
    /// Whether the convert action should appear for this payload. Stored
    /// bitmaps always qualify (they are the payload); a file list qualifies
    /// only when it holds at least one image file, decided by the path
    /// extension's uniform type.
    static func isConvertible(_ payload: PluginClipboardPayload) -> Bool {
        switch payload {
        case .bitmap:
            return true
        case .files(let urls):
            return !imageFileURLs(from: urls).isEmpty
        }
    }

    /// The image files among a file payload's URLs, in stored order;
    /// non-image files are dropped.
    static func imageFileURLs(from urls: [URL]) -> [URL] {
        urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }
    }

    /// Load a payload into basket items: bitmaps stay in memory (output →
    /// Downloads); file lists enter their image files as references (output →
    /// beside the original). Nil when no image file survives on disk.
    static func basketItems(for payload: PluginClipboardPayload) -> [ImageConversionBasketItem]? {
        switch payload {
        case .bitmap(let data, let displayName):
            return [.bitmap(data, displayName: displayName)]
        case .files(let urls):
            let existing = imageFileURLs(from: urls)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { return nil }
            return existing.map { .file($0) }
        }
    }
}
