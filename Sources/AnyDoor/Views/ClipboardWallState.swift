import SwiftUI

/// Observable view state for the clipboard wall: the active category tab, the
/// search query, the rendered items, and the keyboard selection index. The
/// window controller pushes items in (after querying the store) and reads the
/// selection back on Enter.
@MainActor
@Observable
final class ClipboardWallState {
    var category: ClipboardHistoryKind?      // nil == "All"
    /// The live search filter. Driven entirely by the controller's key handler
    /// (type to append, backspace to delete) so it always matches exactly what
    /// the user typed — a focused NSTextField would select-all and mangle it.
    var query: String = ""
    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var selectedIndex: Int = 0

    /// All category tabs in display order: All, then text/image/file, then the
    /// four legacy kinds. `nil` is the leading "All" tab.
    static let categoryOrder: [ClipboardHistoryKind?] = [
        nil, .text, .image, .file, .screenshot, .color, .ocr, .qrcode,
    ]

    func setItems(_ newItems: [ClipboardHistoryItem]) {
        items = newItems
        selectedIndex = min(selectedIndex, max(0, newItems.count - 1))
        if newItems.isEmpty { selectedIndex = 0 }
    }

    var selectedItem: ClipboardHistoryItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func moveLeft() { selectedIndex = max(0, selectedIndex - 1) }
    func moveRight() { selectedIndex = min(max(0, items.count - 1), selectedIndex + 1) }
    func select(_ index: Int) { if items.indices.contains(index) { selectedIndex = index } }
}
