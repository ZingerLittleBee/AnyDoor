import Foundation

/// A complete initial entry. Its enclosing operation ID is the content root;
/// later favorite, recognition, membership, and text edits are separate events.
struct ClipboardSyncEntryContent: Codable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let sourceBundleID: String?
    let sourceDisplayName: String?
    let sourceProvenance: String
    let favorite: Bool
    let tags: [ClipboardSyncTagContent]
    let items: [ClipboardSyncItemContent]
    let facets: [String]
    let recognition: ClipboardSyncRecognitionContent
}

struct ClipboardSyncItemContent: Codable, Equatable, Sendable {
    let representations: [ClipboardSyncRepresentationContent]
}

enum ClipboardSyncRepresentationContent: Codable, Equatable, Sendable {
    case text(typeIdentifier: String, value: String)
    case richText(typeIdentifier: String, data: Data)
    case color(data: Data, normalizedValue: String)
    case bitmap(png: Data, thumbnail: Data)
    case file(ClipboardSyncFileDescriptor)
}

struct ClipboardSyncRecognitionContent: Codable, Equatable, Sendable {
    /// Nil means no completed result; an empty array is a completed empty result.
    let ocr: [String]?
    let qr: [String]?

    init(ocr: [String]? = nil, qr: [String]? = nil) {
        self.ocr = ocr
        self.qr = qr
    }
}
