import Foundation

/// A ready-made Quicklink preset seeded as a real row on first launch, so
/// common destinations (search engines, docs, translators) exist out of the
/// box and can be edited or deleted like any other entry. Pure data: `nameKey`
/// is localized at seed time; `link` and `keyword` are raw values.
///
/// `uuid` is a fixed identity per template (not random) so the same preset
/// seeded on two machines shares one row id — backup/sync then merges them by
/// id instead of duplicating.
struct QuicklinkTemplate: Identifiable, Sendable {
    let id: String
    let uuid: UUID
    let nameKey: L10n.Key
    let link: String
    let keyword: String?
}

enum QuicklinkTemplateCatalog {
    /// Curated common presets, seeded once on first launch. Every link is a
    /// Search Template (`{query}`) so the value is immediate: type the keyword,
    /// a query, and go. The fixed UUIDs are deliberately repetitive-digit so a
    /// seeded row is recognizable and stable across machines.
    static let all: [QuicklinkTemplate] = [
        QuicklinkTemplate(
            id: "google",
            uuid: uuid("A11CE100-0000-4000-8000-000000000001"),
            nameKey: .quicklinkTemplateGoogle,
            link: "https://www.google.com/search?q={query}",
            keyword: "g"
        ),
        QuicklinkTemplate(
            id: "github",
            uuid: uuid("A11CE100-0000-4000-8000-000000000002"),
            nameKey: .quicklinkTemplateGitHub,
            link: "https://github.com/search?q={query}",
            keyword: "gh"
        ),
        QuicklinkTemplate(
            id: "youtube",
            uuid: uuid("A11CE100-0000-4000-8000-000000000003"),
            nameKey: .quicklinkTemplateYouTube,
            link: "https://www.youtube.com/results?search_query={query}",
            keyword: "yt"
        ),
        QuicklinkTemplate(
            id: "stackoverflow",
            uuid: uuid("A11CE100-0000-4000-8000-000000000006"),
            nameKey: .quicklinkTemplateStackOverflow,
            link: "https://stackoverflow.com/search?q={query}",
            keyword: "so"
        ),
        QuicklinkTemplate(
            id: "npm",
            uuid: uuid("A11CE100-0000-4000-8000-000000000007"),
            nameKey: .quicklinkTemplateNpm,
            link: "https://www.npmjs.com/search?q={query}",
            keyword: "npm"
        ),
        QuicklinkTemplate(
            id: "mdn",
            uuid: uuid("A11CE100-0000-4000-8000-000000000008"),
            nameKey: .quicklinkTemplateMDN,
            link: "https://developer.mozilla.org/en-US/search?q={query}",
            keyword: "mdn"
        ),
        QuicklinkTemplate(
            id: "google-translate",
            uuid: uuid("A11CE100-0000-4000-8000-000000000009"),
            nameKey: .quicklinkTemplateGoogleTranslate,
            link: "https://translate.google.com/?sl=auto&tl=zh-CN&text={query}",
            keyword: "fy"
        ),
        QuicklinkTemplate(
            id: "chatgpt",
            uuid: uuid("A11CE100-0000-4000-8000-000000000010"),
            nameKey: .quicklinkTemplateChatGPT,
            link: "https://chatgpt.com/?q={query}",
            keyword: "gpt"
        ),
    ]

    /// Force-unwrap is safe: every argument is a compile-time UUID literal, and
    /// `catalogUUIDsAreValidAndUnique` guards the invariant in tests.
    private static func uuid(_ string: String) -> UUID {
        guard let value = UUID(uuidString: string) else {
            preconditionFailure("Invalid Quicklink template UUID literal: \(string)")
        }
        return value
    }
}
