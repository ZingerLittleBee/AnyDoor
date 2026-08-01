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

    /// How long typing has to settle before a search runs. Long enough to
    /// swallow a burst of keystrokes, short enough not to read as lag.
    private static let searchDebounce = Duration.milliseconds(150)

    /// Injected so tests can drive the debounce with a fake clock instead of
    /// sleeping for real. Production always gets `ContinuousClock`.
    private let clock: any Clock<Duration>
    private var searchTask: Task<Void, Never>?

    init(
        presentation: ClipboardHistoryPresentationModel,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.presentation = presentation
        self.clock = clock
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

    /// Which "nothing here" line fits the current query. An untouched history,
    /// a search that found nothing, and a filter that hides everything are three
    /// different situations; one shared string leaves the user unable to tell
    /// whether their query is wrong or their history is simply empty.
    var emptyStateKey: L10n.Key {
        if !query.isEmpty { return .clipboardEmptySearch }
        if sourceFilterBundleID != nil || category != .all {
            return .clipboardEmptyFilter
        }
        return .clipboardEmpty
    }

    /// Which line explains a store the wall cannot read. This used to reuse
    /// the per-item "cannot preview" string, which reads as one broken entry
    /// rather than a whole history sitting behind a key the app cannot reach —
    /// and says nothing about where the retry and reset actions live. A locked
    /// keychain stays its own line because it is the one case the user fixes
    /// outside AnyDoor, and it resolves on its own once unlocked.
    var unavailableStateKey: L10n.Key {
        guard case .unavailable(let reason) = presentation.contentState,
            reason == .keychainLocked
        else {
            return .clipboardUnavailable
        }
        return .clipboardUnavailableKeychainLocked
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
        searchTask?.cancel()
        searchTask = nil
        await presentation.setQuery(moduleQuery)
    }

    /// A keystroke. Each search costs tens of milliseconds on the module actor
    /// that also serves capture, and a run of keystrokes only ever wants the
    /// last one, so typing coalesces into a single search.
    ///
    /// Clearing the field is exempt: it falls back to the unfiltered browse
    /// query, which is cheap, and delaying it would just feel broken.
    func queryTextDidChange() {
        searchTask?.cancel()
        guard !query.isEmpty else {
            applyQuery()
            return
        }
        searchTask = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            await presentation.setQuery(moduleQuery)
        }
    }

    /// A category or source click. Discrete and deliberate, so it applies
    /// immediately — and it drops any keystroke still waiting, whose text is
    /// already part of the query being applied.
    func filtersDidChange() {
        searchTask?.cancel()
        applyQuery()
    }

    private func applyQuery() {
        searchTask = Task { [weak self] in
            guard let self else { return }
            await presentation.setQuery(moduleQuery)
        }
    }

    func awaitPendingSearchForTesting() async {
        await searchTask?.value
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
