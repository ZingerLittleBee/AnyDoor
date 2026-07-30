import AppKit
import ClipboardHistory
import Foundation

extension ClipboardHistoryEntry {
    var presentationFacet: ClipboardHistoryFacet {
        for facet in [
            ClipboardHistoryFacet.screenshot,
            .image,
            .file,
            .color,
            .qrCode,
            .email,
            .link,
            .text,
        ] where facets.contains(facet) {
            return facet
        }
        return .text
    }

    var presentationTitleKey: L10n.Key {
        switch presentationFacet {
        case .text, .link, .email:
            return .clipboardKindText
        case .color:
            return .clipboardKindColor
        case .image:
            return .clipboardKindImage
        case .screenshot:
            return .clipboardKindScreenshot
        case .file:
            return .clipboardKindFile
        case .qrCode:
            return .clipboardKindQrcode
        }
    }

    @MainActor
    var presentationTitle: String {
        if let previewText, !previewText.isEmpty {
            return previewText
        }
        return L(presentationTitleKey)
    }
}

extension ClipboardHistoryMaterialization {
    var exactTexts: [String]? {
        var result: [String] = []
        for item in items {
            guard let text = item.representations.compactMap({ representation
                -> String? in
                guard case .text(let typeIdentifier, let value) =
                    representation,
                    typeIdentifier == "public.utf8-plain-text"
                else {
                    return nil
                }
                return value
            }).first else {
                return nil
            }
            result.append(text)
        }
        return result
    }

    var editableText: String? {
        guard items.count == 1, let texts = exactTexts, texts.count == 1 else {
            return nil
        }
        return texts[0]
    }

    var firstBitmapData: Data? {
        items.lazy.flatMap(\.representations).compactMap { representation
            -> Data? in
            guard case .data(let typeIdentifier, let data) = representation,
                typeIdentifier == "public.png"
            else {
                return nil
            }
            return data
        }.first
    }

    var fileURLs: [URL] {
        items.flatMap(\.representations).compactMap { representation in
            guard case .file(let file) = representation else { return nil }
            return file.currentURL
        }
    }

    var normalizedColor: NSColor? {
        items.lazy.flatMap(\.representations).compactMap { representation
            -> NSColor? in
            guard case .data(let typeIdentifier, let data) = representation,
                typeIdentifier == NSPasteboard.PasteboardType.color.rawValue
            else {
                return nil
            }
            return NSColor(
                pasteboardPropertyList: data,
                ofType: .color
            )
        }.first
    }
}
