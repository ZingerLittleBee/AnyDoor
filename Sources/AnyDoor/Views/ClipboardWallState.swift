import ClipboardHistory
import SwiftUI

enum ClipboardWallCategory: Hashable {
    case all
    case favorites
    case kind(ClipboardHistoryKind)
    // Link and Email are facets, not display kinds: a link entry still
    // renders as text, so these categories exist beside `kind` instead of
    // widening `ClipboardHistoryKind` with values no entry ever carries.
    case link
    case email
    case tag(String)

    var titleKey: L10n.Key? {
        switch self {
        case .all:
            return .clipboardCategoryAll
        case .favorites:
            return .clipboardCategoryFavorites
        case .kind(let kind):
            return kind.titleKey
        case .link:
            return .clipboardKindLink
        case .email:
            return .clipboardKindEmail
        case .tag:
            return nil
        }
    }

    var facetFilter: ClipboardHistoryFacet? {
        switch self {
        case .all, .favorites, .tag:
            return nil
        case .link:
            return .link
        case .email:
            return .email
        case .kind(let kind):
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
        case .link:
            return "facet:link"
        case .email:
            return "facet:email"
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
    var sourceFilterID: ClipboardHistorySourceID?
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

    /// The selected entry's identity, not its position. A card compares this
    /// once (O(1)) instead of every realized card re-deriving an index by
    /// scanning the whole array, and it stays correct when entries are added
    /// or removed around the selection.
    var selectedID: ClipboardHistoryEntryID? {
        presentation.selectedID
    }

    /// Where the selected entry currently sits, and the wall's scroll-follow
    /// signal. It has to be position rather than identity: a capture landing
    /// while the wall is open prepends an entry and slides the selected card
    /// sideways without changing what is selected, and the card still has to
    /// be brought back to the centre.
    ///
    /// Position is also what makes the signal quiet in the other direction —
    /// appending a page past the selection leaves this unchanged, so
    /// prefetching cannot yank the viewport back to the selected card.
    ///
    /// This is an O(N) scan, so read it **once per body evaluation at the
    /// container level**. Card highlighting compares `selectedID` instead;
    /// reading this from every realized card is what made selection O(R×N).
    var selectedIndex: Int? {
        guard let selectedID = presentation.selectedID else { return nil }
        return items.firstIndex { $0.id == selectedID }
    }

    /// How many cards to each side of the selection the wall materializes as
    /// real views. Comfortably past half a viewport (about 11 cards on a 5K
    /// display), so everything visible — plus a prefetch margin whose cards
    /// can decode their previews before they scroll on screen — is always a
    /// real card.
    static let renderRadius = 60

    /// The slice of `items` rendered as cards. Everything outside it is stood
    /// in for by two fixed-width spacers, so the scroll geometry is identical
    /// to rendering the full list while per-event SwiftUI cost stays O(window)
    /// no matter how many pages are loaded — the wall's viewport is always
    /// anchored to the selection (every scroll input is translated into
    /// selection movement), so off-window cards are never visible.
    var renderWindow: Range<Int> {
        let count = items.count
        guard count > 0 else { return 0..<0 }
        let center = min(max(selectedIndex ?? 0, 0), count - 1)
        let lower = max(0, center - Self.renderRadius)
        let upper = min(count, center + Self.renderRadius + 1)
        return lower..<upper
    }

    /// Which "nothing here" line fits the current query. An untouched history,
    /// a search that found nothing, and a filter that hides everything are three
    /// different situations; one shared string leaves the user unable to tell
    /// whether their query is wrong or their history is simply empty.
    var emptyStateKey: L10n.Key {
        if !query.isEmpty { return .clipboardEmptySearch }
        if sourceFilterID != nil || category != .all {
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
            sourceID: sourceFilterID,
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
                .link,
                .email,
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
        prefetchIfNearTail()
    }

    func select(_ id: ClipboardHistoryEntryID) {
        prefersInstantScroll = false
        presentation.select(id)
        prefetchIfNearTail()
    }

    /// How close the selection may get to the loaded tail before the next page
    /// is requested. Wider than the presentation model's own row-appearance
    /// distance because the wall centres the selection, so up to half a
    /// viewport of cards (about 11 on a 5K display) is already visible to the
    /// selection's right when the trigger fires.
    static let prefetchDistance = 24

    /// The wall pages on *selection*, not on view lifecycle: every route to
    /// the boundary — wheel, arrows, card clicks, ⌘→ — moves the selection, so
    /// this is the one complete signal for "the user is approaching the end of
    /// what is loaded". A trigger tied to the sentinel's view lifetime is not
    /// reliable either way: a LazyHStack never disposes a realized sentinel,
    /// so a boundary-keyed task re-fires after every append and chain-loads
    /// the entire store.
    static func shouldPrefetch(
        selectedIndex: Int?,
        count: Int,
        pagingState: ClipboardHistoryPagingState
    ) -> Bool {
        guard pagingState == .moreAvailable, let selectedIndex else {
            return false
        }
        return selectedIndex + prefetchDistance >= count
    }

    private func prefetchIfNearTail() {
        guard Self.shouldPrefetch(
            selectedIndex: selectedIndex,
            count: items.count,
            pagingState: presentation.pagingState
        ) else { return }
        // Unstructured on purpose: the fetch belongs to the presentation
        // model, not to whichever key press started it. `loadNextPage()` is
        // single-flight, so a run of steps inside the trigger zone still
        // issues one request.
        Task { await presentation.loadNextPage() }
    }

    func moveToStart() {
        prefersInstantScroll = true
        presentation.moveSelectionToStart()
    }

    /// ⌘→. Async because reaching the end of the history may have to fetch the
    /// next page first; the scroll preference is set up front so the jump to the
    /// loaded tail is instant either way.
    func moveToEnd() async {
        prefersInstantScroll = true
        await presentation.moveTowardHistoryEnd()
    }

    func clearSourceFilter() {
        sourceFilterID = nil
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
