import Foundation

/// Placeholder for the translation history store.
///
/// `TranslationCoordinator` (this phase) references `TranslationHistoryStore`
/// as the optional sink for successful translations. The full SwiftData-backed
/// implementation (over the `TranslationRecord` `@Model`) lands in a later task,
/// which replaces this file wholesale. This minimal shell exists only so the
/// coordinator compiles ahead of that work; `history` stays `nil` in tests.
@MainActor
final class TranslationHistoryStore {
    static let shared = TranslationHistoryStore()

    init() {}

    /// Write one successful translation. A nil source language (auto-detect that
    /// produced no detection) is stored as an empty code.
    func record(
        sourceText: String,
        translatedText: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        serviceID: String,
        serviceName: String
    ) {
        // No-op until the SwiftData-backed store is implemented.
    }
}
