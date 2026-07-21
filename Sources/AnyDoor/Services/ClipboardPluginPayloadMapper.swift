import Foundation
import PluginInterface

/// Pure mapping from a clipboard-history entry's fields to the neutral
/// `PluginClipboardPayload` handed to Native Plugins. This only describes the
/// entry — whether an action applies to a payload is each plugin's policy.
/// Kinds without a payload mapping contribute no plugin actions. Kept free of
/// disk and SwiftData so it unit-tests directly.
enum ClipboardPluginPayloadMapper {
    static func payload(
        kind: ClipboardHistoryKind?,
        fileName: String?,
        previewTitle: String,
        files: [ClipboardFileEntry],
        historyDirectory: URL
    ) -> PluginClipboardPayload? {
        switch kind {
        case .screenshot, .image:
            return .bitmap(
                fileURL: fileName.map { historyDirectory.appendingPathComponent($0) },
                displayName: previewTitle
            )
        case .file:
            return .files(files.map { URL(fileURLWithPath: $0.originalPath) })
        case .ocr, .color, .qrcode, .text, .none:
            return nil
        }
    }

    static func payload(
        for item: ClipboardHistoryItem,
        historyDirectory: URL
    ) -> PluginClipboardPayload? {
        payload(
            kind: item.historyKind,
            fileName: item.fileName,
            previewTitle: item.previewTitle,
            files: item.files,
            historyDirectory: historyDirectory
        )
    }
}
