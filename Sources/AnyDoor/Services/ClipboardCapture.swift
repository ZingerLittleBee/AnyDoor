import AppKit
import Foundation

/// The classified result of reading a pasteboard snapshot. A pure value type
/// so capture logic is testable without timers or the live general pasteboard.
enum CapturedClipboard: Sendable, Equatable {
    case text(plain: String, rich: Data?, richType: String?)
    case image(png: Data)
    case files(urls: [URL])
}

/// Side-effect-free pasteboard classification + privacy filtering.
enum ClipboardCapture {
    /// Pasteboard markers set by password managers / apps that opt out of history.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Rich text representations we try to preserve, richest first.
    private static let richTextTypes: [NSPasteboard.PasteboardType] = [.rtf, .html]

    /// Classify a pasteboard's current contents. Returns nil when the content
    /// should not be recorded (concealed/transient/empty/unsupported).
    static func classify(_ pasteboard: NSPasteboard) -> CapturedClipboard? {
        let types = pasteboard.types ?? []
        if types.contains(concealedType) || types.contains(transientType) { return nil }

        // Files take priority over their textual URL representation.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls: urls)
        }

        // Images (excluding the file case handled above).
        if let image = NSImage(pasteboard: pasteboard), let png = pngData(from: image) {
            return .image(png: png)
        }

        // Text, preserving the richest available styled representation.
        if let plain = pasteboard.string(forType: .string) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            for type in richTextTypes {
                if let data = pasteboard.data(forType: type) {
                    return .text(plain: trimmed, rich: data, richType: type.rawValue)
                }
            }
            return .text(plain: trimmed, rich: nil, richType: nil)
        }

        return nil
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
