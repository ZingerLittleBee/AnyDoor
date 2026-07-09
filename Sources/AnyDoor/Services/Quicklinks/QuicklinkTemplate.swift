import Foundation

/// A ready-made Quicklink preset offered when creating a new entry, so common
/// destinations (search engines, docs, translators) don't have to be typed by
/// hand. Pure data: `nameKey` is localized at display time; `link` and
/// `keyword` are raw values. Picking a template pre-fills the editor sheet — it
/// never adds a row directly — so the user can tweak or clear any field first.
struct QuicklinkTemplate: Identifiable, Sendable {
    let id: String
    let nameKey: L10n.Key
    let link: String
    let keyword: String?
    /// SF Symbol shown in the template menu (favicons resolve later, once the
    /// row exists and its link is known).
    let symbol: String
}

enum QuicklinkTemplateCatalog {
    /// Curated common presets. Every link is a Search Template (`{query}`) so the
    /// value is immediate: pick it, type a keyword-triggered query, and go.
    static let all: [QuicklinkTemplate] = [
        QuicklinkTemplate(
            id: "google",
            nameKey: .quicklinkTemplateGoogle,
            link: "https://www.google.com/search?q={query}",
            keyword: "g",
            symbol: "magnifyingglass"
        ),
        QuicklinkTemplate(
            id: "github",
            nameKey: .quicklinkTemplateGitHub,
            link: "https://github.com/search?q={query}",
            keyword: "gh",
            symbol: "chevron.left.forwardslash.chevron.right"
        ),
        QuicklinkTemplate(
            id: "youtube",
            nameKey: .quicklinkTemplateYouTube,
            link: "https://www.youtube.com/results?search_query={query}",
            keyword: "yt",
            symbol: "play.rectangle"
        ),
        QuicklinkTemplate(
            id: "baidu",
            nameKey: .quicklinkTemplateBaidu,
            link: "https://www.baidu.com/s?wd={query}",
            keyword: "bd",
            symbol: "magnifyingglass"
        ),
        QuicklinkTemplate(
            id: "bilibili",
            nameKey: .quicklinkTemplateBilibili,
            link: "https://search.bilibili.com/all?keyword={query}",
            keyword: "bili",
            symbol: "play.tv"
        ),
        QuicklinkTemplate(
            id: "stackoverflow",
            nameKey: .quicklinkTemplateStackOverflow,
            link: "https://stackoverflow.com/search?q={query}",
            keyword: "so",
            symbol: "text.bubble"
        ),
        QuicklinkTemplate(
            id: "npm",
            nameKey: .quicklinkTemplateNpm,
            link: "https://www.npmjs.com/search?q={query}",
            keyword: "npm",
            symbol: "shippingbox"
        ),
        QuicklinkTemplate(
            id: "mdn",
            nameKey: .quicklinkTemplateMDN,
            link: "https://developer.mozilla.org/en-US/search?q={query}",
            keyword: "mdn",
            symbol: "book"
        ),
        QuicklinkTemplate(
            id: "google-translate",
            nameKey: .quicklinkTemplateGoogleTranslate,
            link: "https://translate.google.com/?sl=auto&tl=zh-CN&text={query}",
            keyword: "fy",
            symbol: "character.bubble"
        ),
        QuicklinkTemplate(
            id: "chatgpt",
            nameKey: .quicklinkTemplateChatGPT,
            link: "https://chatgpt.com/?q={query}",
            keyword: "gpt",
            symbol: "sparkles"
        ),
    ]
}
