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

    /// A classification whose costly image PNG encode is still pending.
    /// `NSPasteboard` is main-thread affine, so `classifyDeferred` runs on the
    /// main actor and only captures the (Sendable) `CGImage`; `finalize` performs
    /// the encode and can run off the main actor.
    enum Deferred: Sendable {
        case text(plain: String, rich: Data?, richType: String?)
        case image(CGImage)
        case files(urls: [URL])
    }

    /// Cheap, main-actor classification of a pasteboard's current contents.
    /// Returns nil when the content should not be recorded
    /// (concealed/transient/empty/unsupported). The image case defers its PNG
    /// encode to `finalize`.
    static func classifyDeferred(_ pasteboard: NSPasteboard) -> Deferred? {
        let types = pasteboard.types ?? []
        if types.contains(concealedType) || types.contains(transientType) { return nil }

        // Files take priority over their textual URL representation.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls: urls)
        }

        // Images (excluding the file case handled above). Extract the CGImage
        // here (cheap) and defer the TIFF-materialise + PNG-compress to finalize.
        if let image = NSImage(pasteboard: pasteboard),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return .image(cg)
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

    /// Finish a deferred classification. For images this performs the costly PNG
    /// encode, so prefer calling it OFF the main actor. Returns nil if the image
    /// cannot be encoded.
    static func finalize(_ deferred: Deferred) -> CapturedClipboard? {
        switch deferred {
        case let .text(plain, rich, richType):
            return .text(plain: plain, rich: rich, richType: richType)
        case let .image(cg):
            guard let png = pngData(from: cg) else { return nil }
            return .image(png: png)
        case let .files(urls):
            return .files(urls: urls)
        }
    }

    /// Synchronous classify (tests + non-hot paths): classify then finalize.
    static func classify(_ pasteboard: NSPasteboard) -> CapturedClipboard? {
        guard let deferred = classifyDeferred(pasteboard) else { return nil }
        return finalize(deferred)
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    static func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
