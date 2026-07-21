import Foundation

/// A block-level element parsed from plugin-authored markdown.
///
/// SwiftUI `Text(AttributedString)` renders a run's *inline* styling — bold,
/// italic, inline code, links — but ignores block-level `PresentationIntent`s
/// (headings, list items, paragraph and code-block boundaries, thematic rules).
/// A whole document handed to a single `Text` therefore collapses into one
/// run-on paragraph. `MarkdownBlocks` recovers the block structure with the
/// *system* parser only (spec 018 forbids third-party renderers), so the palette
/// Detail can lay the blocks out as a styled `VStack`.
enum MarkdownBlock: Equatable {
    /// An ATX/Setext heading (`#`…`######`), 1...6, with its inline-styled text.
    case heading(level: Int, text: AttributedString)
    /// A body paragraph with its inline-styled text.
    case paragraph(AttributedString)
    /// A list item. `ordinal` is the 1-based number for an ordered list, or nil
    /// for an unordered (bulleted) list.
    case listItem(ordinal: Int?, text: AttributedString)
    /// A fenced or indented code block, rendered verbatim (no inline styling).
    case codeBlock(String)
    /// A thematic break (`---`), rendered as a divider.
    case thematicBreak
}

/// Pure markdown → `[MarkdownBlock]` splitter built on the system markdown
/// parser. Kept free of SwiftUI so it can be unit-tested directly; the palette's
/// SwiftUI layout of the blocks stays view-internal and untested per convention.
enum MarkdownBlocks {
    /// Split `markdown` into presentation blocks. Parses with `.full`
    /// interpreted syntax (which emits block-level `PresentationIntent`s),
    /// groups consecutive runs by their intent — each markdown block gets a
    /// distinct intent identity, so paragraph/heading/list boundaries fall out
    /// of a simple equality check — then classifies each group. Falls back to a
    /// single paragraph of the raw text if the parser throws.
    static func blocks(from markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.paragraph(AttributedString(trimmed))]
        }

        var blocks: [MarkdownBlock] = []
        var currentIntent: PresentationIntent?
        var currentText = AttributedString()
        var hasGroup = false

        func flush() {
            guard hasGroup else { return }
            if let block = makeBlock(intent: currentIntent, text: currentText) {
                blocks.append(block)
            }
            currentText = AttributedString()
            hasGroup = false
        }

        for run in attributed.runs {
            let intent = run.presentationIntent
            if !hasGroup {
                currentIntent = intent
                hasGroup = true
            } else if intent != currentIntent {
                flush()
                currentIntent = intent
                hasGroup = true
            }
            currentText.append(attributed[run.range])
        }
        flush()

        return blocks
    }

    /// Classify one intent-grouped run into a block. Multiple intent components
    /// can co-exist (a paragraph nested inside a list item), so the most
    /// specific block kind wins in priority order.
    private static func makeBlock(intent: PresentationIntent?, text: AttributedString) -> MarkdownBlock? {
        guard let intent else {
            let content = trimmed(text)
            return content.characters.isEmpty ? nil : .paragraph(content)
        }

        var headingLevel: Int?
        var listOrdinal: Int?
        var isOrdered = false
        var isCodeBlock = false
        var isThematicBreak = false

        for component in intent.components {
            switch component.kind {
            case .header(let level): headingLevel = level
            case .listItem(let ordinal): listOrdinal = ordinal
            case .orderedList: isOrdered = true
            case .codeBlock: isCodeBlock = true
            case .thematicBreak: isThematicBreak = true
            default: break
            }
        }

        // A thematic break carries no meaningful text, so classify it first.
        if isThematicBreak { return .thematicBreak }

        if isCodeBlock {
            let code = String(text.characters)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            return code.isEmpty ? nil : .codeBlock(code)
        }

        let content = trimmed(text)
        guard !content.characters.isEmpty else { return nil }

        if let headingLevel {
            return .heading(level: headingLevel, text: content)
        }
        if listOrdinal != nil {
            return .listItem(ordinal: isOrdered ? listOrdinal : nil, text: content)
        }
        return .paragraph(content)
    }

    /// Drop leading and trailing whitespace/newline characters while preserving
    /// the surviving runs' inline attributes (`AttributedString` has no
    /// `trimmingCharacters`).
    private static func trimmed(_ input: AttributedString) -> AttributedString {
        var result = input
        while let last = result.characters.last, last.isWhitespace {
            let end = result.characters.endIndex
            let before = result.characters.index(before: end)
            result.removeSubrange(before..<end)
        }
        while let first = result.characters.first, first.isWhitespace {
            let start = result.characters.startIndex
            let after = result.characters.index(after: start)
            result.removeSubrange(start..<after)
        }
        return result
    }
}
