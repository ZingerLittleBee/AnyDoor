import Foundation

extension ClipboardHistoryModule {
    /// `preview_text` is what a card renders, and a list page carries one copy
    /// of it per row. It is a preview, not the content: the full text always
    /// stays in the entry's representations, where the preview panel, the
    /// editor and paste read it from.
    ///
    /// Storing the whole canonical text there is what made a large copy fatal.
    /// Capture accepts plaintext up to 128 MiB (`maximumByteCount`), so a
    /// single such copy put 128 MiB into every page load and handed it to
    /// SwiftUI's text layout, which measured the entire string on every pass —
    /// gigabytes resident and a layout loop that never settled, with the wall
    /// too slow to even delete the offending entry.
    static let previewTextCharacterLimit = 4_096

    /// The stored form of a preview: at most `previewTextCharacterLimit`
    /// characters. Cheap for ordinary text (the prefix walk stops at the
    /// limit), so it is applied on every write rather than only to big values.
    static func boundedPreviewText(_ text: String) -> String {
        String(text.prefix(previewTextCharacterLimit))
    }
}
