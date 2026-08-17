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

    func testGlobalTiersLiftALaterSectionPrefixAboveAnEarlierOther() {
        let sections = [
            (name: "commands", titles: ["Watch", "Keep Awake"]),
            (name: "apps", titles: ["Warp"]),
        ]
        let ranked = CommandPaletteQueryMatch.rankedByGlobalTiers(sections, items: \.titles) {
            CommandPaletteQueryMatch.rank(titles: [$0], query: "wa")
        }
        XCTAssertEqual(ranked.map(\.section.name), ["commands", "apps", "commands"])
        XCTAssertEqual(ranked.flatMap(\.items), ["Watch", "Warp", "Keep Awake"])
        XCTAssertEqual(ranked.map(\.rank), [.prefix, .prefix, .other])
    }

    private func rank(title: String, query: String) -> CommandPaletteQueryMatch.Rank? {
        CommandPaletteQueryMatch.rank(titles: [title], query: query)
    }
}
