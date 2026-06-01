import SwiftUI

/// Observable view state for the clipboard wall: the active category tab, the
/// search query, the rendered items, and the keyboard selection index. The
/// window controller pushes items in (after querying the store) and reads the
/// selection back on Enter.
@MainActor
@Observable
final class ClipboardWallState {
    var category: ClipboardHistoryKind?      // nil == "All"
    /// The live search filter. Edited through the focusable `WallSearchField`
    /// (a real NSTextField, so an input method editor can compose CJK text) when
    /// in input mode; the controller also clears it on Esc.
    var query: String = ""
    /// Whether the search field currently owns keyboard focus (input mode). When
    /// false the wall is in card-navigation mode: arrow keys move the selection,
    /// Enter pastes, etc. The window controller flips this to switch modes and
    /// the `WallSearchField` follows it to grab or release first responder.
    var isSearchFocused: Bool = false
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
