import Foundation

/// Membership and ranking for a command-palette text query.
///
/// A title or secondary field is a candidate when it contains the query
/// (`localizedCaseInsensitiveContains`); a word-start alias only when the
/// query starts it or one of its words. Ranking then orders those survivors
/// so a title that starts with the query outranks a later or fuzzier hit.
/// Query normalization is a whitespace trim, matching the palette's existing
/// filter.
enum CommandPaletteQueryMatch {
    /// Lower is better. Exact titles stay ahead of a mere prefix; a prefix
    /// stays ahead of substring, word-later, alias, or subtitle hits.
    enum Rank: Int, CaseIterable, Comparable {
        case exact = 0
        case prefix = 1
        case other = 2

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// Distinguishes a title-search slice when the same section header is
        /// emitted once per rank tier.
        var identitySuffix: String {
            switch self {
            case .exact: return "exact"
            case .prefix: return "prefix"
            case .other: return "other"
            }
        }
    }

    /// Stable sort key: rank first, then the item's original index so equal
    /// ranks keep the established order.
    struct Key: Comparable {
        let rank: Rank
        let index: Int

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.index < rhs.index
        }
    }

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best rank across `titles` (exact / prefix / later-in-text). `secondary`
    /// fields (aliases, subtitles) and `wordStartAliases` can only contribute
    /// `.other`, so they never outrank a real title prefix. A `secondary`
    /// field hits anywhere it contains the query; a word-start alias only
    /// where the query starts the alias or one of its whitespace-separated
    /// words, so "rec" finds "screen recording" and "ding" does not. `nil`
    /// means the candidate set excludes this item.
    static func rank(
        titles: [String],
        secondary: [String] = [],
        wordStartAliases: [String] = [],
        query: String
    ) -> Rank? {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return nil }

        var best: Rank?
        for title in titles where !title.isEmpty {
            guard title.localizedCaseInsensitiveContains(needle) else { continue }
            let rank = rank(title: title, needle: needle)
            if best.map({ rank < $0 }) ?? true {
                best = rank
            }
            if best == .exact { return .exact }
        }
        if let best { return best }
        if secondary.contains(where: { $0.localizedCaseInsensitiveContains(needle) })
            || wordStartAliases.contains(where: { matchesAtWordStart($0, needle: needle) }) {
            return .other
        }
        return nil
    }

    /// Filters out non-candidates and stably sorts the rest by rank.
    static func ranked<T>(_ items: [T], rank: (T) -> Rank?) -> [(item: T, rank: Rank)] {
        items.enumerated().compactMap { index, item -> (T, Rank, Key)? in
            guard let rank = rank(item) else { return nil }
            return (item, rank, Key(rank: rank, index: index))
        }
        .sorted { $0.2 < $1.2 }
        .map { (item: $0.0, rank: $0.1) }
    }

    /// Emits each section once per rank tier that has survivors, in tier order
    /// then original section order. Flattened items are therefore globally
    /// rank-correct; a section may appear more than once if it spans tiers.
    static func rankedByGlobalTiers<Section, Item>(
        _ sections: [Section],
        items: (Section) -> [Item],
        rank: (Item) -> Rank?
    ) -> [(section: Section, items: [Item], rank: Rank)] {
        let prepared = sections.map { section in
            let scored = items(section).enumerated().compactMap { index, item -> (Item, Int, Rank)? in
                guard let rank = rank(item) else { return nil }
                return (item, index, rank)
            }
            return (section, scored)
        }
        return Rank.allCases.flatMap { band in
            prepared.compactMap { section, scored -> (Section, [Item], Rank)? in
                let slice = scored.filter { $0.2 == band }.sorted { $0.1 < $1.1 }.map(\.0)
                guard !slice.isEmpty else { return nil }
                return (section, slice, band)
            }
        }
    }

    private static func rank(title: String, needle: String) -> Rank {
        if title.localizedCaseInsensitiveCompare(needle) == .orderedSame {
            return .exact
        }
        if starts(title, with: needle, at: title.startIndex) {
            return .prefix
        }
        return .other
    }

    private static func matchesAtWordStart(_ alias: String, needle: String) -> Bool {
        var atWordStart = true
        for index in alias.indices {
            if alias[index].isWhitespace {
                atWordStart = true
                continue
            }
            if atWordStart, starts(alias, with: needle, at: index) {
                return true
            }
            atWordStart = false
        }
        return false
    }

    /// Whether `text` from `start` begins with `needle`, in the same
    /// comparison family as `localizedCaseInsensitiveContains`:
    /// current-locale, case-insensitive, including Unicode equivalence.
    /// Do not drop the locale — a nil-locale `.anchored` range can refuse
    /// prefix rank to a candidate the contains check already accepted.
    private static func starts(_ text: String, with needle: String, at start: String.Index) -> Bool {
        text.range(
            of: needle,
            options: [.caseInsensitive, .anchored],
            range: start..<text.endIndex,
            locale: .current
        ) != nil
    }
}
