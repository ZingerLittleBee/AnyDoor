import ClipboardHistory
import Foundation

enum ClipboardHistoryKind: String, CaseIterable, Sendable {
    case ocr
    case color
    case qrcode
    case screenshot
    case text
    case image
    case video
    case file

    var titleKey: L10n.Key {
        switch self {
        case .ocr:        return .clipboardKindOcr
        case .color:      return .clipboardKindColor
        case .qrcode:     return .clipboardKindQrcode
        case .screenshot: return .clipboardKindScreenshot
        case .text:       return .clipboardKindText
        case .image:      return .clipboardKindImage
        case .video:      return .clipboardKindVideo
        case .file:       return .clipboardKindFile
        }
    }

    /// The Content Facet a Facet Filter for this display kind matches. The
    /// clipboard wall chips and the menu-bar history popover both resolve
    /// through this one mapping, so the two surfaces cannot drift apart.
    var contentFacet: ClipboardHistoryFacet {
        switch self {
        case .ocr:        return .ocr
        case .color:      return .color
        case .qrcode:     return .qrCode
        case .screenshot: return .screenshot
        case .text:       return .text
        case .image:      return .image
        case .video:      return .video
        case .file:       return .file
        }
    }

    /// Kinds whose payload is a plain string in `text` — the ones the floating
    /// text panel can preview and edit.
    var isTextBearing: Bool {
        switch self {
        case .text, .ocr, .qrcode: return true
        case .color, .screenshot, .image, .video, .file: return false
        }
    }
}
