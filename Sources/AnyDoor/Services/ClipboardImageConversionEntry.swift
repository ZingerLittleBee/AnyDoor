import Foundation
import UniformTypeIdentifiers

/// Pure policy for funneling clipboard-history entries into the Image
/// Conversion window: which entries expose the 「图片格式转换」 action, and which
/// of a file entry's files are images. Kept free of disk and SwiftData so it
/// unit-tests directly.
enum ClipboardImageConversionEntry {
    /// Whether the convert-image action should appear for an entry of this kind.
    /// Screenshot and image entries always qualify (their stored bitmap is the
    /// payload); a file entry qualifies only when it holds at least one image
    /// file; every other kind never does.
    static func isConvertible(kind: ClipboardHistoryKind?, files: [ClipboardFileEntry]) -> Bool {
        switch kind {
        case .screenshot, .image:
            return true
        case .file:
            return !imageFileURLs(from: files).isEmpty
        case .ocr, .color, .qrcode, .text, .none:
            return false
        }
    }

    /// The original-path URLs of the image files inside a `.file` entry, in
    /// stored order; non-image files are dropped. Membership is decided by the
    /// path extension's uniform type, matching the card's own image check.
    static func imageFileURLs(from files: [ClipboardFileEntry]) -> [URL] {
        files
            .map { URL(fileURLWithPath: $0.originalPath) }
            .filter { hasImageExtension($0) }
    }

    private static func hasImageExtension(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }
}
