import Foundation
import SwiftData

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

/// One file inside a `.file` clipboard entry. `storedName` is the copy held in
/// the history directory; `originalName` is shown on the card. For
/// reference-only entries (over the size ceiling) `storedName` is nil and the
/// original on-disk path is kept in `originalPath` for write-back.
struct ClipboardFileEntry: Codable, Sendable, Hashable {
    var storedName: String?
    var originalName: String
    var originalPath: String
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

    // Paste-style additions.
    var richData: Data?
    var richType: String?
    var sourceBundleID: String?
    var sourceAppName: String?
    var isFavorite: Bool = false
    var filesManifest: Data?
    var isReferenceOnly: Bool = false

    init(
        id: UUID = UUID(),
        kind: ClipboardHistoryKind,
        text: String? = nil,
        fileName: String? = nil,
        colorHex: String? = nil,
        previewTitle: String,
        previewSubtitle: String? = nil,
        createdAt: Date = Date(),
        richData: Data? = nil,
        richType: String? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        isFavorite: Bool = false,
        filesManifest: Data? = nil,
        isReferenceOnly: Bool = false
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.text = text
        self.fileName = fileName
        self.colorHex = colorHex
        self.previewTitle = previewTitle
        self.previewSubtitle = previewSubtitle
        self.createdAt = createdAt
        self.richData = richData
        self.richType = richType
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.isFavorite = isFavorite
        self.filesManifest = filesManifest
        self.isReferenceOnly = isReferenceOnly
    }

    @Transient var historyKind: ClipboardHistoryKind? {
        ClipboardHistoryKind(rawValue: kind)
    }

    /// Decoded file manifest for `.file` entries, or `[]`.
    @Transient var files: [ClipboardFileEntry] {
        guard let filesManifest else { return [] }
        return (try? JSONDecoder().decode([ClipboardFileEntry].self, from: filesManifest)) ?? []
    }
}
