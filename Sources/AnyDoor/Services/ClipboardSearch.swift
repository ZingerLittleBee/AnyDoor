import Foundation

/// Pure, testable filtering for clipboard history. Kept separate from the
/// SwiftUI view and the SwiftData store so the matching rules can be unit-tested
/// and shared by both the wall (`@Query`-backed) and the store's `timeline`.
///
/// Design goals (so results line up with what the user typed and sees):
/// - Match the copied *content*, never the metadata subtitle ("12 字符" / "3 行"),
///   which would otherwise let a digit or "字符" produce confusing matches.
/// - Tokenize on whitespace and require EVERY token to appear (AND semantics),
///   so a multi-word query stays precise instead of matching the literal joined
///   string.
/// - Preserve the input (recency) order; filtering never reorders results.
enum ClipboardSearch {

    /// Narrow `items` to the given category, favorite flag, and query.
    static func filter(_ items: [ClipboardHistoryItem],
                       category: ClipboardHistoryKind?,
                       favoritesOnly: Bool = false,
                       query: String) -> [ClipboardHistoryItem] {
        var rows = items
        if favoritesOnly {
            rows = rows.filter(\.isFavorite)
        }
        if let category {
            let raw = category.rawValue
            rows = rows.filter { $0.kind == raw }
        }
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return rows }
        return rows.filter { item in
            let haystack = searchableText(for: item)
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// Fold case, diacritics, and width so "cafe" matches "café" and "123"
    /// matches full-width "１２３" — closer to what a user expects than a plain
    /// lowercased comparison.
    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                       locale: .current)
    }

    /// Split a raw query into folded, non-empty whitespace-delimited tokens.
    static func tokenize(_ query: String) -> [String] {
        fold(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// The folded text a query is matched against: the entry's content only.
    /// Excludes `previewSubtitle` (line/char counts) by design.
    static func searchableText(for item: ClipboardHistoryItem) -> String {
        var parts: [String] = [item.previewTitle]
        if let text = item.text { parts.append(text) }
        if let hex = item.colorHex { parts.append(hex) }
        for file in item.files {
            parts.append(file.originalName)
            parts.append(file.originalPath)
        }
        return fold(parts.joined(separator: "\n"))
    }

    /// When a query matches an item only on text *below* the visible first line,
    /// return the most relevant line so the card can show why it matched. Returns
    /// nil when the query is empty, when the title already contains a token
    /// (nothing to add), or when no single line carries a token.
    static func matchSnippet(for item: ClipboardHistoryItem, query: String) -> String? {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return nil }
        let title = fold(item.previewTitle)
        if tokens.contains(where: { title.contains($0) }) { return nil }
        guard let text = item.text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let folded = fold(String(line))
            if tokens.contains(where: { folded.contains($0) }) {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
