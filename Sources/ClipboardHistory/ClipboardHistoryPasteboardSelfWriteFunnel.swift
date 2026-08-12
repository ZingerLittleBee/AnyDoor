import AppKit

public final class ClipboardHistoryPasteboardSelfWriteToken: Sendable {
    private let token: ClipboardHistorySelfWriteSuppression.Token

    init(token: ClipboardHistorySelfWriteSuppression.Token) {
        self.token = token
    }

    @MainActor
    public func finish(pasteboard: NSPasteboard = .general) {
        token.finish(generation: pasteboard.changeCount)
    }
}

public final class ClipboardHistoryPasteboardSelfWriteFunnel: Sendable {
    private let suppression: ClipboardHistorySelfWriteSuppression

    public init() {
        suppression = ClipboardHistorySelfWriteSuppression()
    }

    init(suppression: ClipboardHistorySelfWriteSuppression) {
        self.suppression = suppression
    }

    @MainActor
    public func begin() -> ClipboardHistoryPasteboardSelfWriteToken {
        ClipboardHistoryPasteboardSelfWriteToken(token: suppression.begin())
    }

    @discardableResult
    @MainActor
    public func perform<T>(
        to pasteboard: NSPasteboard = .general,
        _ body: (NSPasteboard) throws -> T
    ) rethrows -> T {
        let token = begin()
        defer { token.finish(pasteboard: pasteboard) }
        return try body(pasteboard)
    }

    @MainActor
    public func write(
        string: String,
        to pasteboard: NSPasteboard = .general
    ) {
        perform(to: pasteboard) { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        }
    }

    public func consumesSuppressedGeneration(_ generation: Int) -> Bool {
        suppression.shouldSuppress(generation: generation)
    }
}
