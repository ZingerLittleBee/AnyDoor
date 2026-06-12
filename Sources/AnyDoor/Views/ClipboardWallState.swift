import SwiftUI

/// A clipboard-wall filter tab. `favorites` and `tag` cut across kinds, so
/// they are their own cases rather than a `ClipboardHistoryKind`.
enum ClipboardWallCategory: Hashable {
    case all
    case favorites
    case kind(ClipboardHistoryKind)
    /// A user-defined category; the payload is the `ClipboardTag.id`.
    case tag(String)

    /// L10n key for builtin tabs; nil for custom tags, whose free-form names
    /// come from `ClipboardTagStore` instead.
    var titleKey: L10n.Key? {
        switch self {
        case .all: return .clipboardCategoryAll
        case .favorites: return .clipboardCategoryFavorites
        case .kind(let kind): return kind.titleKey
        case .tag: return nil
        }
    }

    /// The kind to narrow by; nil for the cross-kind tabs.
    var kindFilter: ClipboardHistoryKind? {
        if case .kind(let kind) = self { return kind }
        return nil
    }

    /// The tag id to narrow by; nil for builtin tabs.
    var tagFilter: String? {
        if case .tag(let id) = self { return id }
        return nil
    }
}

/// Observable view state for the clipboard wall: the active category tab, the
/// search query, the rendered items, and the keyboard selection index. The
/// window controller pushes items in (after querying the store) and reads the
/// selection back on Enter.
@MainActor
@Observable
final class ClipboardWallState {
    var category: ClipboardWallCategory = .all
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

    /// The in-wall tag dialog (create / rename / delete-confirm). Rendered as
    /// an overlay by `ClipboardWallView`; the window controller routes Return
    /// and Esc to commit/cancel while this is non-nil.
    enum TagDialog {
        case create(item: ClipboardHistoryItem)
        case rename(tagID: String)
        case confirmDelete(tagID: String)
    }
    var tagDialog: TagDialog?
    /// Backing text for the dialog's name field.
    var tagDialogText: String = ""

    /// One-stop dialog presenter: seeds the name field, releases search focus
    /// (the overlay owns the keyboard), and raises the dialog.
    func presentTagDialog(_ dialog: TagDialog, initialText: String = "") {
        tagDialogText = initialText
        isSearchFocused = false
        tagDialog = dialog
    }

    /// Tab display order: All and Favorites, then the user's custom tags in
    /// registry order, then the kind tabs.
    static func order(tags: [ClipboardTag]) -> [ClipboardWallCategory] {
        [.all, .favorites]
            + tags.map { .tag($0.id) }
            + [.kind(.text), .kind(.image), .kind(.file),
               .kind(.screenshot), .kind(.color), .kind(.ocr), .kind(.qrcode)]
    }

    /// The current tab order; the view pushes a fresh order in whenever the
    /// tag registry changes. Kept on the state so Tab-cycling is testable.
    private(set) var categories: [ClipboardWallCategory] = ClipboardWallState.order(tags: [])

    func setCategories(_ order: [ClipboardWallCategory]) {
        guard order != categories else { return }
        categories = order
        // The active tag may have just been deleted; never strand the wall on
        // a tab that no longer exists.
        if !order.contains(category) { category = .all }
    }

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

    /// Cycle the active category tab (Tab / Shift-Tab), wrapping at both ends.
    func selectNextCategory() { stepCategory(by: 1) }
    func selectPreviousCategory() { stepCategory(by: -1) }

    private func stepCategory(by delta: Int) {
        let order = categories
        let current = order.firstIndex(of: category) ?? 0
        category = order[(current + delta + order.count) % order.count]
    }
}
