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
    /// A blockquote (`> …`). Consecutive paragraphs of the *same* quote are
    /// merged into one block (joined by blank lines) so a multi-paragraph quote
    /// renders as a single quoted unit; separate quotes stay separate blocks.
    case blockquote(AttributedString)
    /// A markdown image (`![alt](url)`), surfaced as its own block so the
    /// Detail can render an inline preview. Confined to http/https — the same
    /// scheme allowlist every other plugin-authored URL boundary enforces
    /// (ADR-0009); a `file://` or custom-scheme image is dropped, never loaded.
    case image(URL)
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
        // Blockquote identity of the last appended block, used to merge the
        // paragraphs of one quote while keeping distinct quotes separate.
        var lastQuoteIdentity: Int?

        func flush() {
            guard hasGroup else { return }
            if let block = makeBlock(intent: currentIntent, text: currentText) {
                let quoteIdentity = currentIntent.flatMap(Self.quoteIdentity)
                if case .blockquote(let text) = block,
                   quoteIdentity != nil, quoteIdentity == lastQuoteIdentity,
                   case .blockquote(var merged) = blocks[blocks.count - 1] {
                    merged.append(AttributedString("\n\n"))
                    merged.append(text)
                    blocks[blocks.count - 1] = .blockquote(merged)
                } else {
                    blocks.append(block)
                    lastQuoteIdentity = {
                        if case .blockquote = block { return quoteIdentity }
                        return nil
                    }()
                }
            }
            currentText = AttributedString()
            hasGroup = false
        }

        for run in attributed.runs {
            // An image run carries its URL as an attribute while sharing the
            // surrounding paragraph's intent, so it must break the group here:
            // text before it flushes, the image becomes its own block, and text
            // after it starts a fresh group. (A quote interrupted by an image
            // intentionally resumes as a separate quote block — the merge guard
            // only extends a quote when it is still the last block.)
            if let imageURL = run.imageURL {
                flush()
                if let scheme = imageURL.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    blocks.append(.image(imageURL))
                    lastQuoteIdentity = nil
                }
                continue
            }
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
        var isBlockquote = false

        for component in intent.components {
            switch component.kind {
            case .header(let level): headingLevel = level
            case .listItem(let ordinal): listOrdinal = ordinal
            case .orderedList: isOrdered = true
            case .codeBlock: isCodeBlock = true
            case .thematicBreak: isThematicBreak = true
            case .blockQuote: isBlockquote = true
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

        // A quote wins over anything nested inside it (`> # title`), so the
        // whole quote renders as one quoted unit.
        if isBlockquote {
            return .blockquote(content)
        }
        if let headingLevel {
            return .heading(level: headingLevel, text: content)
        }
        if listOrdinal != nil {
            return .listItem(ordinal: isOrdered ? listOrdinal : nil, text: content)
        }
        return .paragraph(content)
    }

    /// The parser-assigned identity of the blockquote containing this intent,
    /// or nil when the intent is not inside a quote. Two paragraphs share an
    /// identity exactly when they belong to the same source quote.
    private static func quoteIdentity(_ intent: PresentationIntent) -> Int? {
        for component in intent.components {
            if case .blockQuote = component.kind { return component.identity }
        }
        return nil
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
