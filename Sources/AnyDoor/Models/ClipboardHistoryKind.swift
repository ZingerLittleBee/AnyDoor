import Foundation

enum ClipboardHistoryKind: String, CaseIterable, Sendable {
    case ocr
    case color
    case qrcode
    case screenshot
    case text
    case image
    case file

    var titleKey: L10n.Key {
        switch self {
        case .ocr:        return .clipboardKindOcr
        case .color:      return .clipboardKindColor
        case .qrcode:     return .clipboardKindQrcode
        case .screenshot: return .clipboardKindScreenshot
        case .text:       return .clipboardKindText
        case .image:      return .clipboardKindImage
        case .file:       return .clipboardKindFile
        }
    }

    /// Kinds whose payload is a plain string in `text` — the ones the floating
    /// text panel can preview and edit.
    var isTextBearing: Bool {
        switch self {
        case .text, .ocr, .qrcode: return true
        case .color, .screenshot, .image, .file: return false
        }
    }
}
