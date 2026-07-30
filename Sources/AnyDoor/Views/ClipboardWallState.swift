import ClipboardHistory
import SwiftUI

enum ClipboardWallCategory: Hashable {
    case all
    case favorites
    case kind(ClipboardHistoryKind)
    case tag(String)

    var titleKey: L10n.Key? {
        switch self {
        case .all:
            return .clipboardCategoryAll
        case .favorites:
            return .clipboardCategoryFavorites
        case .kind(let kind):
            return kind.titleKey
        case .tag:
            return nil
        }
    }

    var facetFilter: ClipboardHistoryFacet? {
        guard case .kind(let kind) = self else { return nil }
        switch kind {
        case .text, .ocr:
            return .text
        case .color:
            return .color
        case .qrcode:
            return .qrCode
        case .screenshot:
            return .screenshot
        case .image:
            return .image
        case .file:
            return .file
        }
    }

    var kindFilter: ClipboardHistoryKind? {
        if case .kind(let kind) = self { return kind }
        return nil
    }

    var tagFilter: String? {
        if case .tag(let id) = self { return id }
        return nil
    }

    var persistentID: String {
        switch self {
        case .all:
            return "all"
        case .favorites:
            return "favorites"
        case .kind(let kind):
            return "kind:\(kind.rawValue)"
        case .tag(let id):
            return "tag:\(id)"
        }
    }
}

@MainActor
@Observable
final class ClipboardWallState {
    let presentation: ClipboardHistoryPresentationModel

    var category: ClipboardWallCategory = .all
    var sourceFilterBundleID: String?
    var query = ""
    var isSearchFocused = false
    private(set) var prefersInstantScroll = false

    enum TagDialog {
        case create(entryID: ClipboardHistoryEntryID)
        case rename(tagID: String)
        case confirmDelete(tagID: String)
    }

    var tagDialog: TagDialog?
    var tagDialogText = ""
    var isReorderModifierHeld = false

    private(set) var categories =
        ClipboardWallState.order(tags: [])
    private(set) var sourceMenuOpenToken = 0

    init(presentation: ClipboardHistoryPresentationModel) {
        self.presentation = presentation
    }

    var items: [ClipboardHistoryEntry] {
        presentation.entries
    }

    var selectedItem: ClipboardHistoryEntry? {
        presentation.selectedEntry
    }

    var selectedIndex: Int {
        guard let selectedID = presentation.selectedID else { return 0 }
        return items.firstIndex { $0.id == selectedID } ?? 0
    }

    var moduleQuery: ClipboardHistoryQuery {
        ClipboardHistoryQuery(
            text: query,
            facet: category.facetFilter,
            sourceID: sourceFilterBundleID,
            tagID: category.tagFilter,
            favoritesOnly: category == .favorites
        )
    }

    func reload() async {
        if presentation.query == moduleQuery {
            await presentation.reload()
        } else {
            await presentation.setQuery(moduleQuery)
        }
    }

    func refreshQuery() async {
        await presentation.setQuery(moduleQuery)
    }

    func prefetchIfNeeded(visibleID: ClipboardHistoryEntryID) async {
        await presentation.prefetchIfNeeded(visibleID: visibleID)
    }

    func presentTagDialog(
        _ dialog: TagDialog,
        initialText: String = ""
    ) {
        guard tagDialog == nil else { return }
        tagDialogText = initialText
        isSearchFocused = false
        tagDialog = dialog
    }

    static func order(
        tags: [ClipboardHistoryTagDefinition]
    ) -> [ClipboardWallCategory] {
        [.all, .favorites]
            + tags.map { .tag($0.id) }
            + [
                .kind(.text),
                .kind(.image),
                .kind(.file),
                .kind(.screenshot),
                .kind(.color),
                .kind(.ocr),
                .kind(.qrcode),
            ]
    }

    func setCategories(_ order: [ClipboardWallCategory]) {
        guard order != categories else { return }
        categories = order
        if !order.contains(category) {
            category = .all
        }
    }

    func moveLeft() {
        prefersInstantScroll = false
        presentation.moveSelection(by: -1)
    }

    func moveRight() {
        prefersInstantScroll = false
        presentation.moveSelection(by: 1)
    }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        prefersInstantScroll = false
        presentation.select(items[index].id)
    }

    func moveToStart() {
        prefersInstantScroll = true
        presentation.moveSelectionToStart()
    }

    func moveToEnd() {
        prefersInstantScroll = true
        presentation.moveSelectionToEnd()
    }

    func clearSourceFilter() {
        sourceFilterBundleID = nil
    }

    func requestOpenSourceMenu() {
        sourceMenuOpenToken += 1
    }

    func selectNextCategory() {
        stepCategory(by: 1)
    }

    func selectPreviousCategory() {
        stepCategory(by: -1)
    }

    private func stepCategory(by delta: Int) {
        let current = categories.firstIndex(of: category) ?? 0
        category = categories[
            (current + delta + categories.count) % categories.count
        ]
    }
}
