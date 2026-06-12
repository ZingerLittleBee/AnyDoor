import XCTest
@testable import AnyDoor

/// Behavioral tests for `ClipboardSearch` — the pure matching logic shared by
/// the clipboard wall and the store's timeline.
final class ClipboardSearchTests: XCTestCase {

    // MARK: - Builders

    private func text(_ body: String, title: String? = nil,
                      subtitle: String? = nil, app: String? = nil) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            kind: .text,
            text: body,
            previewTitle: title ?? body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body,
            previewSubtitle: subtitle,
            sourceAppName: app
        )
    }

    private func color(_ hex: String) -> ClipboardHistoryItem {
        ClipboardHistoryItem(kind: .color, colorHex: hex, previewTitle: hex)
    }

    private func file(named name: String, path: String) -> ClipboardHistoryItem {
        let manifest = try! JSONEncoder().encode(
            [ClipboardFileEntry(storedName: nil, originalName: name, originalPath: path)]
        )
        return ClipboardHistoryItem(kind: .file, previewTitle: name, filesManifest: manifest)
    }

    private func titles(_ items: [ClipboardHistoryItem]) -> [String] {
        items.map(\.previewTitle)
    }

    // MARK: - Empty / passthrough

    func testEmptyQueryReturnsEverythingInOrder() {
        let items = [text("alpha"), text("beta"), text("gamma")]
        let out = ClipboardSearch.filter(items, category: nil, query: "")
        XCTAssertEqual(titles(out), ["alpha", "beta", "gamma"])
    }

    func testWhitespaceOnlyQueryReturnsEverything() {
        let items = [text("alpha"), text("beta")]
        let out = ClipboardSearch.filter(items, category: nil, query: "   \t ")
        XCTAssertEqual(titles(out), ["alpha", "beta"])
    }

    // MARK: - Content matching

    func testMatchesTitleSubstring() {
        let items = [text("portunus-standalone"), text("codex session log")]
        let out = ClipboardSearch.filter(items, category: nil, query: "codex")
        XCTAssertEqual(titles(out), ["codex session log"])
    }

    func testNonMatchingQueryReturnsEmpty() {
        // The exact symptom from the bug report: "codex" must NOT surface items
        // whose content does not contain it.
        let items = [text("portunus-standalone"), text("Z3mMK9JcpzobC@j6"),
                     text("38.64.56.236"), text("便宜且消除崩溃路径")]
        let out = ClipboardSearch.filter(items, category: nil, query: "codex")
        XCTAssertTrue(out.isEmpty)
    }

    func testIsCaseInsensitive() {
        let items = [text("Hello World")]
        XCTAssertEqual(ClipboardSearch.filter(items, category: nil, query: "hello").count, 1)
        XCTAssertEqual(ClipboardSearch.filter(items, category: nil, query: "WORLD").count, 1)
    }

    func testTrimsSurroundingWhitespace() {
        let items = [text("swift concurrency")]
        XCTAssertEqual(ClipboardSearch.filter(items, category: nil, query: "  swift  ").count, 1)
    }

    func testMatchesFullTextBelowFirstLine() {
        let items = [text("title line\nsecond line mentions codex here")]
        XCTAssertEqual(ClipboardSearch.filter(items, category: nil, query: "codex").count, 1)
    }

    func testMatchesCJKContent() {
        let items = [text("便宜且消除崩溃路径"), text("其他内容")]
        let out = ClipboardSearch.filter(items, category: nil, query: "崩溃")
        XCTAssertEqual(titles(out), ["便宜且消除崩溃路径"])
    }

    func testDiacriticInsensitiveMatching() {
        let items = [text("café au lait"), text("plain coffee")]
        let out = ClipboardSearch.filter(items, category: nil, query: "cafe")
        XCTAssertEqual(titles(out), ["café au lait"])
    }

    func testDiacriticInsensitiveBothDirections() {
        // An accented query must also find unaccented content.
        let items = [text("naive approach")]
        XCTAssertEqual(ClipboardSearch.filter(items, category: nil, query: "naïve").count, 1)
    }

    func testFullWidthDigitsMatchHalfWidthQuery() {
        let items = [text("port １２３４")]
        XCTAssertEqual(ClipboardSearch.filter(items, category: nil, query: "1234").count, 1)
    }

    // MARK: - Multi-token AND semantics

    func testAllTokensMustMatch() {
        let items = [text("git push origin main"),
                     text("git status"),
                     text("svn push")]
        let out = ClipboardSearch.filter(items, category: nil, query: "git push")
        XCTAssertEqual(titles(out), ["git push origin main"])
    }

    func testTokensMayMatchDifferentFields() {
        // "report" in the body, "pdf" in the file name — both tokens satisfied.
        let item = file(named: "report.pdf", path: "/tmp/report.pdf")
        let out = ClipboardSearch.filter([item], category: nil, query: "report pdf")
        XCTAssertEqual(out.count, 1)
    }

    // MARK: - Field selection

    func testSubtitleMetadataIsNotSearched() {
        // previewSubtitle holds "12 字符" / "3 行" style metadata; searching it
        // must not match, or numbers and unit words produce phantom hits.
        let item = text("hello", subtitle: "12 字符")
        XCTAssertTrue(ClipboardSearch.filter([item], category: nil, query: "字符").isEmpty)
        XCTAssertTrue(ClipboardSearch.filter([item], category: nil, query: "12").isEmpty)
    }

    func testColorHexIsSearchable() {
        let items = [color("#FF8800"), color("#00AAFF")]
        let out = ClipboardSearch.filter(items, category: nil, query: "ff88")
        XCTAssertEqual(titles(out), ["#FF8800"])
    }

    func testFileNameIsSearchable() {
        let items = [file(named: "invoice.pdf", path: "/tmp/invoice.pdf"),
                     file(named: "photo.png", path: "/tmp/photo.png")]
        let out = ClipboardSearch.filter(items, category: nil, query: "invoice")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.previewTitle, "invoice.pdf")
    }

    // MARK: - Category narrowing

    func testCategoryNarrowsBeforeQuery() {
        let t = text("blue note")
        let c = color("#0000FF")
        let out = ClipboardSearch.filter([t, c], category: .color, query: "0000")
        XCTAssertEqual(titles(out), ["#0000FF"])
    }

    func testCategoryAloneNarrowsWithoutQuery() {
        let t = text("a")
        let c = color("#111111")
        let out = ClipboardSearch.filter([t, c], category: .text, query: "")
        XCTAssertEqual(titles(out), ["a"])
    }

    // MARK: - Favorites narrowing

    func testFavoritesOnlyKeepsFavoritesAcrossKinds() {
        let t = text("plain")
        let fav = text("starred")
        fav.isFavorite = true
        let favColor = color("#FF8800")
        favColor.isFavorite = true
        let out = ClipboardSearch.filter([t, fav, favColor], category: nil,
                                         favoritesOnly: true, query: "")
        XCTAssertEqual(titles(out), ["starred", "#FF8800"])
    }

    func testFavoritesOnlyComposesWithQuery() {
        let fav = text("starred codex")
        fav.isFavorite = true
        let plain = text("codex plain")
        let out = ClipboardSearch.filter([fav, plain], category: nil,
                                         favoritesOnly: true, query: "codex")
        XCTAssertEqual(titles(out), ["starred codex"])
    }

    // MARK: - Order preservation

    func testRecencyOrderIsPreserved() {
        let items = [text("codex one"), text("two"), text("codex three")]
        let out = ClipboardSearch.filter(items, category: nil, query: "codex")
        XCTAssertEqual(titles(out), ["codex one", "codex three"])
    }

    // MARK: - Match snippet

    func testSnippetNilWhenTitleAlreadyMatches() {
        let item = text("codex session\ndetails")
        XCTAssertNil(ClipboardSearch.matchSnippet(for: item, query: "codex"))
    }

    func testSnippetNilForEmptyQuery() {
        let item = text("anything\nhere")
        XCTAssertNil(ClipboardSearch.matchSnippet(for: item, query: ""))
    }

    func testSnippetReturnsMatchedLineBelowTitle() {
        let item = text("first line\n  the codex reference  \nlast line")
        XCTAssertEqual(ClipboardSearch.matchSnippet(for: item, query: "codex"),
                       "the codex reference")
    }

    func testSnippetNilWhenNoLineMatches() {
        let item = text("first line\nsecond line")
        XCTAssertNil(ClipboardSearch.matchSnippet(for: item, query: "codex"))
    }
}
