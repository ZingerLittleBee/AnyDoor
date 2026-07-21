import Foundation
import XCTest
@testable import AnyDoor

/// Pure tests for the markdown block splitter that backs the palette Detail. The
/// SwiftUI layout of the blocks is view-internal and untested per repo
/// convention; the block model that feeds it is pinned here.
final class MarkdownBlocksTests: XCTestCase {

    private func plainText(_ block: MarkdownBlock?) -> String? {
        switch block {
        case .heading(_, let text), .paragraph(let text), .listItem(_, let text):
            return String(text.characters)
        case .codeBlock(let code):
            return code
        case .thematicBreak, .none:
            return nil
        }
    }

    // MARK: - Headings

    func testHeadingLevelsAreDistinguished() {
        let blocks = MarkdownBlocks.blocks(from: "# One\n\n## Two\n\n### Three")
        XCTAssertEqual(blocks.count, 3)
        guard case .heading(let l1, _) = blocks[0],
              case .heading(let l2, _) = blocks[1],
              case .heading(let l3, _) = blocks[2] else {
            return XCTFail("expected three headings, got \(blocks)")
        }
        XCTAssertEqual(l1, 1)
        XCTAssertEqual(l2, 2)
        XCTAssertEqual(l3, 3)
        XCTAssertEqual(plainText(blocks[0]), "One")
        XCTAssertEqual(plainText(blocks[2]), "Three")
    }

    func testHeadingFollowedByParagraphAreSeparateBlocks() {
        let blocks = MarkdownBlocks.blocks(from: "# Title\n\nBody text here.")
        XCTAssertEqual(blocks.count, 2)
        guard case .heading = blocks[0], case .paragraph = blocks[1] else {
            return XCTFail("expected heading then paragraph, got \(blocks)")
        }
        XCTAssertEqual(plainText(blocks[1]), "Body text here.")
    }

    // MARK: - Paragraphs

    func testBlankLineSeparatedParagraphsStaySeparate() {
        let blocks = MarkdownBlocks.blocks(from: "First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(plainText(blocks[0]), "First paragraph.")
        XCTAssertEqual(plainText(blocks[1]), "Second paragraph.")
    }

    func testSingleNewlineWithinParagraphDoesNotSplitBlocks() {
        // A single newline is a soft break inside one paragraph, not a new block.
        let blocks = MarkdownBlocks.blocks(from: "Line one\nline two")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph = blocks[0] else {
            return XCTFail("expected one paragraph, got \(blocks)")
        }
    }

    // MARK: - Lists

    func testUnorderedListItemsBecomeBulletedBlocks() {
        let blocks = MarkdownBlocks.blocks(from: "- Alpha\n- Beta\n- Gamma")
        let items = blocks.compactMap { block -> (Int?, String)? in
            guard case .listItem(let ordinal, let text) = block else { return nil }
            return (ordinal, String(text.characters))
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.0 == nil }, "unordered items carry no ordinal")
        XCTAssertEqual(items.map(\.1), ["Alpha", "Beta", "Gamma"])
    }

    func testOrderedListItemsCarryTheirOrdinal() {
        let blocks = MarkdownBlocks.blocks(from: "1. First\n2. Second\n3. Third")
        let items = blocks.compactMap { block -> Int? in
            guard case .listItem(let ordinal, _) = block else { return nil }
            return ordinal
        }
        XCTAssertEqual(items, [1, 2, 3])
    }

    // MARK: - Thematic break

    func testThematicBreakBecomesItsOwnBlock() {
        let blocks = MarkdownBlocks.blocks(from: "Above\n\n---\n\nBelow")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(plainText(blocks[0]), "Above")
        guard case .thematicBreak = blocks[1] else {
            return XCTFail("expected a thematic break in the middle, got \(blocks)")
        }
        XCTAssertEqual(plainText(blocks[2]), "Below")
        // The literal dashes must not leak into any rendered text block.
        XCTAssertFalse(blocks.contains { plainText($0)?.contains("---") == true })
    }

    // MARK: - Code block

    func testFencedCodeBlockIsCapturedVerbatim() {
        let markdown = "```\nlet x = 1\nprint(x)\n```"
        let blocks = MarkdownBlocks.blocks(from: markdown)
        let code = blocks.compactMap { block -> String? in
            guard case .codeBlock(let code) = block else { return nil }
            return code
        }
        XCTAssertEqual(code, ["let x = 1\nprint(x)"])
    }

    // MARK: - Inline styling survival

    func testInlineStylingSurvivesInParagraph() {
        let blocks = MarkdownBlocks.blocks(from: "Text with **bold**, *italic* and `code`.")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text) = blocks[0] else {
            return XCTFail("expected a paragraph, got \(blocks)")
        }
        // Inline intents must survive on their runs (bold/italic/inline-code).
        let hasBoldOrItalic = text.runs.contains { $0.inlinePresentationIntent != nil }
        XCTAssertTrue(hasBoldOrItalic, "expected inline emphasis/code intents to be preserved")
        XCTAssertEqual(String(text.characters), "Text with bold, italic and code.")
    }

    func testLinkSurvivesAsTappableAttribute() {
        let blocks = MarkdownBlocks.blocks(from: "See [the site](https://example.com) now.")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text) = blocks[0] else {
            return XCTFail("expected a paragraph, got \(blocks)")
        }
        let link = text.runs.compactMap(\.link).first
        XCTAssertEqual(link, URL(string: "https://example.com"))
    }

    // MARK: - Composite document

    func testMixedDocumentPreservesEveryBlockKind() {
        let markdown = """
        # Heading

        A paragraph.

        - Item one
        - Item two

        ---

        Closing paragraph.
        """
        let blocks = MarkdownBlocks.blocks(from: markdown)
        var kinds: [String] = []
        for block in blocks {
            switch block {
            case .heading: kinds.append("heading")
            case .paragraph: kinds.append("paragraph")
            case .listItem: kinds.append("listItem")
            case .codeBlock: kinds.append("codeBlock")
            case .thematicBreak: kinds.append("thematicBreak")
            }
        }
        XCTAssertEqual(
            kinds,
            ["heading", "paragraph", "listItem", "listItem", "thematicBreak", "paragraph"]
        )
    }

    // MARK: - Degenerate input

    func testEmptyMarkdownYieldsNoBlocks() {
        XCTAssertTrue(MarkdownBlocks.blocks(from: "").isEmpty)
        XCTAssertTrue(MarkdownBlocks.blocks(from: "   \n\n  ").isEmpty)
    }
}
