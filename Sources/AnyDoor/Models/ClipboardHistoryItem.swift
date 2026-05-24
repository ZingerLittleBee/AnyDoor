import Foundation
import SwiftData

enum ClipboardHistoryKind: String, CaseIterable, Sendable {
    case ocr
    case color
    case qrcode
    case screenshot

    var titleKey: L10n.Key {
        switch self {
        case .ocr:        return .clipboardKindOcr
        case .color:      return .clipboardKindColor
        case .qrcode:     return .clipboardKindQrcode
        case .screenshot: return .clipboardKindScreenshot
        }
    }
}

@Model
final class ClipboardHistoryItem {
    @Attribute(.unique) var id: UUID
    var kind: String
    var text: String?
    var fileName: String?
    var colorHex: String?
    var previewTitle: String
    var previewSubtitle: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: ClipboardHistoryKind,
        text: String? = nil,
        fileName: String? = nil,
        colorHex: String? = nil,
        previewTitle: String,
        previewSubtitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.text = text
        self.fileName = fileName
        self.colorHex = colorHex
        self.previewTitle = previewTitle
        self.previewSubtitle = previewSubtitle
        self.createdAt = createdAt
    }

    @Transient var historyKind: ClipboardHistoryKind? {
        ClipboardHistoryKind(rawValue: kind)
    }
}
