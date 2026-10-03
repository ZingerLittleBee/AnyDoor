import XCTest
@testable import AnyDoor

final class CommandPaletteMatchTests: XCTestCase {

    func testTitlePrefixOutranksLaterSubstring() {
        XCTAssertEqual(rank(title: "Warp", query: "wa"), .prefix)
        XCTAssertEqual(rank(title: "Keep Awake", query: "wa"), .other)
        XCTAssertLessThan(
            CommandPaletteQueryMatch.Rank.prefix,
            CommandPaletteQueryMatch.Rank.other
        )
    }

    func testPrefixRankIsCaseInsensitive() {
        XCTAssertEqual(rank(title: "Warp", query: "WA"), .prefix)
        XCTAssertEqual(rank(title: "WARP", query: "wa"), .prefix)
        XCTAssertEqual(rank(title: "warp", query: "Wa"), .prefix)
    }

    func testExactTitleOutranksPrefix() {
        XCTAssertEqual(rank(title: "Wa", query: "wa"), .exact)
        XCTAssertEqual(rank(title: "Warp", query: "wa"), .prefix)
        XCTAssertLessThan(
            CommandPaletteQueryMatch.Rank.exact,
            CommandPaletteQueryMatch.Rank.prefix
        )
    }

    func testWhitespaceNormalizedQueryStillPrefixes() {
        XCTAssertEqual(rank(title: "Warp", query: "  wa  "), .prefix)
        XCTAssertEqual(rank(title: "Keep Awake", query: "\twa\n"), .other)
    }

    func testAliasOnlyMatchIsOtherAndStillACandidate() {
        let rank = CommandPaletteQueryMatch.rank(
            titles: ["GitHub"],
            secondary: ["gh"],
            query: "gh"
        )
        XCTAssertEqual(rank, .other)
    }

    func testAliasCannotOutrankATitlePrefix() {
        let aliasHit = CommandPaletteQueryMatch.rank(
            titles: ["Keep Awake"],
            secondary: ["wa"],
            query: "wa"
        )
        let prefixHit = CommandPaletteQueryMatch.rank(titles: ["Warp"], query: "wa")
        XCTAssertEqual(aliasHit, .other)
        XCTAssertEqual(prefixHit, .prefix)
        XCTAssertLessThan(prefixHit!, aliasHit!)
    }

    func testWordStartAliasMatchesOnlyAtTheStartOfAWord() {
        // Record Screen in the Chinese UI: its title lacks every query here.
        func aliasRank(_ query: String) -> CommandPaletteQueryMatch.Rank? {
            CommandPaletteQueryMatch.rank(
                titles: ["录制屏幕"],
                wordStartAliases: ["screen recording"],
                query: query
            )
        }
        XCTAssertEqual(aliasRank("rec"), .other)
        XCTAssertEqual(aliasRank("recording"), .other)
        XCTAssertEqual(aliasRank("RECORDING"), .other)
        XCTAssertEqual(aliasRank("screen rec"), .other)
        XCTAssertEqual(aliasRank("screen recording"), .other, "an alias never ranks as an exact title")
        XCTAssertNil(aliasRank("ding"))
        XCTAssertNil(aliasRank("cording"))
        XCTAssertNil(aliasRank("en rec"))
    }

    func testWordStartAliasRejectsAHitInsideItsOnlyWord() {
        // "sho" sits inside "screenshot" but starts none of its words.
        func aliasRank(_ query: String) -> CommandPaletteQueryMatch.Rank? {
            CommandPaletteQueryMatch.rank(
                titles: ["截图"],
                wordStartAliases: ["screenshot"],
                query: query
            )
        }
        XCTAssertNil(aliasRank("sho"))
        XCTAssertNil(aliasRank("shot"))
        XCTAssertEqual(aliasRank("scr"), .other)
    }

    func testSecondaryAliasStillMatchesInsideAWord() {
        // App aliases keep substring matching: a Chinese-UI user finds 微信
        // by typing "chat", through its English name.
        let rank = CommandPaletteQueryMatch.rank(
            titles: ["微信"],
            secondary: ["WeChat"],
            query: "chat"
        )
        XCTAssertEqual(rank, .other)
    }

    func testNonCandidateReturnsNil() {
        XCTAssertNil(rank(title: "Finder", query: "wa"))
        XCTAssertNil(CommandPaletteQueryMatch.rank(titles: ["Warp"], query: "   "))
        XCTAssertNil(CommandPaletteQueryMatch.rank(titles: ["Warp"], query: ""))
    }

    func testRankedDropsNonCandidatesAndKeepsEqualRankOrder() {
        let titles = ["Keep Awake", "Finder", "Always On", "Watch", "Water"]
        let ranked = CommandPaletteQueryMatch.ranked(titles) {
            CommandPaletteQueryMatch.rank(titles: [$0], query: "wa")
        }
        XCTAssertEqual(ranked.map(\.item), ["Watch", "Water", "Keep Awake", "Always On"])
        XCTAssertEqual(ranked.map(\.rank), [.prefix, .prefix, .other, .other])
    }

    func testRankedPrefersExactThenPrefixThenOther() {
        let titles = ["Keep Awake", "Watch", "Wa"]
        let ranked = CommandPaletteQueryMatch.ranked(titles) {
            CommandPaletteQueryMatch.rank(titles: [$0], query: "wa")
        }
        XCTAssertEqual(ranked.map(\.item), ["Wa", "Watch", "Keep Awake"])
        XCTAssertEqual(ranked.map(\.rank), [.exact, .prefix, .other])
    }

    func testPrefixRankFollowsLocalizedUnicodeEquivalence() {
        // Precomposed É (U+00C9) vs decomposed e + combining acute. Candidate
        // matching uses localized case-insensitive contains against the
        // current locale; prefix rank must accept the same start.
        let precomposed = "\u{00C9}clair"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(rank(title: precomposed, query: decomposed), .prefix)
        XCTAssertEqual(rank(title: "Keep \u{00C9}clair", query: decomposed), .other)
        XCTAssertEqual(rank(title: "E\u{0301}clair", query: "\u{00E9}"), .prefix)
    }

    func testExactRankFollowsLocalizedUnicodeEquivalence() {
        XCTAssertEqual(
            rank(title: "\u{00C9}clair", query: "e\u{0301}clair"),
            .exact
        )
    }

    func testRankedBySectionEmitsEachSectionOnceWhenItSpansTiers() {
        // Interleaving case: capture holds an exact and later hits, translation
        // a prefix in between. Each header must appear once.
        let sections = [
            (name: "capture", titles: ["截图", "窗口截图", "全屏截图"]),
            (name: "translation", titles: ["截图翻译"]),
        ]
        let grouped = CommandPaletteQueryMatch.rankedBySection(sections, items: \.titles) {
            CommandPaletteQueryMatch.rank(titles: [$0], query: "截图")
        }
        XCTAssertEqual(grouped.map(\.section.name), ["capture", "translation"])
        XCTAssertEqual(grouped.flatMap(\.items), ["截图", "窗口截图", "全屏截图", "截图翻译"])
    }

    func testRankedBySectionOrdersSectionsByTheirBestItem() {
        let sections = [
            (name: "commands", titles: ["Keep Awake", "Always On"]),
            (name: "translation", titles: ["Wa Translate"]),
            (name: "apps", titles: ["Warp", "Wa"]),
        ]
        let grouped = CommandPaletteQueryMatch.rankedBySection(sections, items: \.titles) {
            CommandPaletteQueryMatch.rank(titles: [$0], query: "wa")
        }
        // apps (exact) > translation (prefix) > commands (other); within apps
        // the exact "Wa" precedes the prefix "Warp".
        XCTAssertEqual(grouped.map(\.section.name), ["apps", "translation", "commands"])
        XCTAssertEqual(
            grouped.flatMap(\.items),
            ["Wa", "Warp", "Wa Translate", "Keep Awake", "Always On"]
        )
    }

    func testRankedBySectionKeepsSectionOrderOnEqualBestRankAndDropsEmptySections() {
        let sections = [
            (name: "commands", titles: ["Watch", "Keep Awake"]),
            (name: "empty", titles: ["Lock Screen"]),
            (name: "apps", titles: ["Warp"]),
        ]
        let grouped = CommandPaletteQueryMatch.rankedBySection(sections, items: \.titles) {
            CommandPaletteQueryMatch.rank(titles: [$0], query: "wa")
        }
        XCTAssertEqual(grouped.map(\.section.name), ["commands", "apps"])
        XCTAssertEqual(grouped.flatMap(\.items), ["Watch", "Keep Awake", "Warp"])
    }

    private func rank(title: String, query: String) -> CommandPaletteQueryMatch.Rank? {
        CommandPaletteQueryMatch.rank(titles: [title], query: query)
    }
}
