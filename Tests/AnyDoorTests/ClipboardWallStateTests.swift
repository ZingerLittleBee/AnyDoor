import Clocks
import XCTest
import ClipboardHistory
@testable import AnyDoor

@MainActor
final class ClipboardWallStateTests: XCTestCase {
    private func entries(_ titles: [String]) -> [ClipboardHistoryEntry] {
        titles.enumerated().map { idx, t in
            ClipboardHistoryEntry(
                id: ClipboardHistoryEntryID(UUID()),
                capturedAt: Date(
                    timeIntervalSinceReferenceDate: Double(idx)
                ),
                previewText: t,
                facets: [.text],
                isFavorite: false,
                source: .unknown
            )
        }
    }

    private func makeState(
        entries: [ClipboardHistoryEntry] = [],
        availability: ClipboardHistoryStatus.Availability = .ready,
        reason: ClipboardHistoryStatus.AvailabilityReason? = nil
    ) async -> ClipboardWallState {
        await makeState(
            feed: ClipboardWallEntryFeed(entries),
            availability: availability,
            reason: reason
        )
    }

    private func makeState(
        feed: ClipboardWallEntryFeed,
        availability: ClipboardHistoryStatus.Availability = .ready,
        reason: ClipboardHistoryStatus.AvailabilityReason? = nil
    ) async -> ClipboardWallState {
        let presentation = ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: availability,
                        reason: reason,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { _, _ in await feed.page() },
                apply: { _ in .notFound },
                materialize: { _ in
                    ClipboardHistoryMaterialization(items: [])
                },
                tagDefinitions: { [] }
            )
        )
        await presentation.load()
        return ClipboardWallState(presentation: presentation)
    }

    func testSelectionClampsAndMoves() async {
        let items = entries(["a", "b", "c"])
        let state = await makeState(entries: items)
        XCTAssertEqual(state.selectedID, items[0].id)
        state.moveRight(); state.moveRight(); state.moveRight()   // clamps at last
        XCTAssertEqual(state.selectedID, items[2].id)
        state.moveLeft()
        XCTAssertEqual(state.selectedID, items[1].id)
        XCTAssertEqual(state.selectedItem?.previewText, "b")
    }

    /// Clicking a card selects that entry, and an ID the wall is not showing
    /// (a card deleted between the click and its handler) leaves the current
    /// selection alone rather than clearing it.
    func testSelectingByIDPicksThatEntryAndIgnoresUnknownIDs() async {
        let items = entries(["a", "b", "c"])
        let state = await makeState(entries: items)

        state.select(items[2].id)
        XCTAssertEqual(state.selectedID, items[2].id)
        XCTAssertEqual(state.selectedItem?.previewText, "c")

        let stranger = entries(["gone"])[0]
        state.select(stranger.id)
        XCTAssertEqual(state.selectedID, items[2].id)
    }

    /// A capture landing while the wall is open prepends an entry, so every
    /// index shifts by one. Selection is held by ID, so the card the user
    /// picked stays selected instead of the wall jumping to its neighbour —
    /// while `selectedIndex` does move, which is what tells the wall to
    /// re-centre the card that just slid sideways.
    func testSelectionSurvivesAnEntryAppend() async {
        let original = entries(["a", "b", "c"])
        let feed = ClipboardWallEntryFeed(original)
        let state = await makeState(feed: feed)
        state.select(original[1].id)
        XCTAssertEqual(state.selectedIndex, 1)

        let captured = entries(["x"])
        await feed.replace(with: captured + original)
        await state.reload()

        XCTAssertEqual(state.items.count, 4)
        XCTAssertEqual(state.selectedID, original[1].id)
        XCTAssertEqual(state.selectedItem?.previewText, "b")
        // The scroll-follow signal moved; the selection did not.
        XCTAssertEqual(state.selectedIndex, 2)
    }

    /// The other half of the scroll-follow contract: a page appended past the
    /// selection must leave the signal alone, or prefetching while the user
    /// scrolls would drag the viewport back to the selected card.
    func testAppendingPastTheSelectionLeavesTheScrollSignalAlone() async {
        let original = entries(["a", "b", "c"])
        let feed = ClipboardWallEntryFeed(original)
        let state = await makeState(feed: feed)
        state.select(original[1].id)
        XCTAssertEqual(state.selectedIndex, 1)

        await feed.replace(with: original + entries(["d", "e"]))
        await state.reload()

        XCTAssertEqual(state.items.count, 5)
        XCTAssertEqual(state.selectedIndex, 1)
    }

    func testEmptyStateTellsSearchFilterAndAnEmptyHistoryApart() async {
        // One "暂无历史" for all three left the user unable to tell a bad query
        // from an empty history.
        let state = await makeState()
        XCTAssertEqual(state.emptyStateKey, .clipboardEmpty)

        state.category = .kind(.image)
        XCTAssertEqual(state.emptyStateKey, .clipboardEmptyFilter)

        state.category = .all
        state.sourceFilterID = .application("com.apple.Safari")
        XCTAssertEqual(state.emptyStateKey, .clipboardEmptyFilter)

        // A query outranks a filter: the user is looking at their own search.
        state.query = "nothing matches this"
        XCTAssertEqual(state.emptyStateKey, .clipboardEmptySearch)
        state.sourceFilterID = nil
        XCTAssertEqual(state.emptyStateKey, .clipboardEmptySearch)
    }

    func testAnUnavailableStoreIsNamedInsteadOfLookingLikeABrokenPreview()
        async
    {
        // Deleting the Keychain master key left the wall showing the per-item
        // "无法预览" line, indistinguishable from one bad entry and silent about
        // the retry/reset that live in Settings.
        let missingKey = await makeState(
            availability: .unavailable,
            reason: .missingKey
        )
        XCTAssertEqual(missingKey.unavailableStateKey, .clipboardUnavailable)

        // A locked keychain fixes itself once unlocked, so it must not tell the
        // user to go reset their history.
        let locked = await makeState(
            availability: .paused,
            reason: .keychainLocked
        )
        XCTAssertEqual(
            locked.unavailableStateKey,
            .clipboardUnavailableKeychainLocked
        )

        // A store that is fine never renders the branch, but the key must still
        // be a safe generic rather than the locked-keychain claim.
        let ready = await makeState()
        XCTAssertEqual(ready.unavailableStateKey, .clipboardUnavailable)
    }

    func testCategoryAndSearchAreHeld() async {
        let state = await makeState()
        state.category = .kind(.image)
        state.query = "foo"
        state.sourceFilterID = .application("com.apple.Safari")
        XCTAssertEqual(state.category, .kind(.image))
        XCTAssertEqual(state.query, "foo")
        XCTAssertEqual(
            state.sourceFilterID,
            .application("com.apple.Safari")
        )
    }

    func testCategoryCyclingWrapsBothWays() async {
        let state = await makeState()
        XCTAssertEqual(state.category, .all)
        state.selectNextCategory()
        XCTAssertEqual(state.category, .favorites)
        state.selectPreviousCategory()
        XCTAssertEqual(state.category, .all)
        // Wrap backwards from the first tab to the last, and forward again.
        state.selectPreviousCategory()
        XCTAssertEqual(state.category, state.categories.last)
        state.selectNextCategory()
        XCTAssertEqual(state.category, .all)
    }

    func testCyclingIncludesCustomTags() async {
        let state = await makeState()
        let tags = [
            ClipboardHistoryTagDefinition(id: "t1", displayName: "工作")
        ]
        state.setCategories(ClipboardWallState.order(tags: tags))
        state.selectNextCategory()   // .all → .favorites
        state.selectNextCategory()   // .favorites → .tag("t1")
        XCTAssertEqual(state.category, .tag("t1"))
    }

    func testSetCategoriesFallsBackToAllWhenActiveTagRemoved() async {
        let state = await makeState()
        state.setCategories(
            ClipboardWallState.order(
                tags: [
                    ClipboardHistoryTagDefinition(
                        id: "t1",
                        displayName: "工作"
                    )
                ]
            )
        )
        state.category = .tag("t1")
        state.setCategories(ClipboardWallState.order(tags: []))
        XCTAssertEqual(state.category, .all)
    }

    func testSetCategoriesKeepsActiveTagWhenStillPresent() async {
        let state = await makeState()
        let tags = [
            ClipboardHistoryTagDefinition(id: "t1", displayName: "工作")
        ]
        state.setCategories(ClipboardWallState.order(tags: tags))
        state.category = .tag("t1")
        state.setCategories(
            ClipboardWallState.order(
                tags: tags + [
                    ClipboardHistoryTagDefinition(
                        id: "t2",
                        displayName: "生活"
                    )
                ]
            )
        )
        XCTAssertEqual(state.category, .tag("t1"))
    }

    func testTagFilterAccessors() {
        XCTAssertEqual(ClipboardWallCategory.tag("t1").tagFilter, "t1")
        XCTAssertNil(ClipboardWallCategory.tag("t1").kindFilter)
        XCTAssertNil(ClipboardWallCategory.all.tagFilter)
        XCTAssertNil(ClipboardWallCategory.tag("t1").titleKey)
    }

    func testCategoryKindFilter() {
        XCTAssertNil(ClipboardWallCategory.all.kindFilter)
        XCTAssertNil(ClipboardWallCategory.favorites.kindFilter)
        XCTAssertEqual(ClipboardWallCategory.kind(.text).kindFilter, .text)
    }

    func testLinkAndEmailCategoriesFilterByFacet() {
        XCTAssertEqual(ClipboardWallCategory.link.facetFilter, .link)
        XCTAssertEqual(ClipboardWallCategory.email.facetFilter, .email)
        XCTAssertNil(ClipboardWallCategory.link.kindFilter)
        XCTAssertNil(ClipboardWallCategory.email.kindFilter)
        XCTAssertNil(ClipboardWallCategory.link.tagFilter)
        XCTAssertEqual(ClipboardWallCategory.link.persistentID, "facet:link")
        XCTAssertEqual(ClipboardWallCategory.email.persistentID, "facet:email")
    }

    func testDefaultOrderListsLinkAndEmailAfterText() {
        let order = ClipboardWallState.order(tags: [])
        guard let text = order.firstIndex(of: .kind(.text)) else {
            return XCTFail("Text category missing from default order")
        }
        XCTAssertEqual(order[text + 1], .link)
        XCTAssertEqual(order[text + 2], .email)
    }

    func testEmptyItemsHasNilSelection() async {
        let state = await makeState()
        XCTAssertNil(state.selectedItem)
        XCTAssertNil(state.selectedID)
        XCTAssertNil(state.selectedIndex)
    }

    func testClearingSourceFilterRestoresAllSources() async {
        let state = await makeState()
        state.sourceFilterID = .application("com.apple.Safari")
        state.clearSourceFilter()
        XCTAssertNil(state.sourceFilterID)
    }

    func testRefreshQuerySendsEveryFilterToModule() async {
        let recorder = ClipboardWallQueryRecorder()
        let presentation = ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { query, _ in
                    await recorder.record(query)
                    return ClipboardHistoryPage(
                        entries: [],
                        nextCursor: nil
                    )
                },
                apply: { _ in .notFound },
                materialize: { _ in
                    ClipboardHistoryMaterialization(items: [])
                },
                tagDefinitions: { [] }
            )
        )
        let state = ClipboardWallState(presentation: presentation)
        state.query = "needle"
        state.category = .kind(.image)
        state.sourceFilterID = .application("com.example.Source")

        await state.refreshQuery()

        let query = await recorder.lastQuery
        XCTAssertEqual(query?.text, "needle")
        XCTAssertEqual(query?.facet, .image)
        XCTAssertEqual(
            query?.sourceID,
            .application("com.example.Source")
        )
    }

    /// Every keystroke used to fire its own search on the module actor that
    /// also serves capture. A run of them only ever wants the last one.
    func testATypingBurstCoalescesIntoASingleSearch() async throws {
        let clock = TestClock()
        let recorder = ClipboardWallQueryRecorder()
        let state = ClipboardWallState(
            presentation: makeRecordingPresentation(recorder),
            clock: clock
        )

        for text in ["s", "sw", "swi", "swif", "swift"] {
            state.query = text
            state.queryTextDidChange()
        }
        await clock.advance(by: .milliseconds(149))
        let recorded = await recorder.count
        XCTAssertEqual(recorded, 0)

        await clock.advance(by: .milliseconds(1))
        await state.awaitPendingSearchForTesting()
        let texts = await recorder.queryTexts
        XCTAssertEqual(texts, ["swift"])
    }

    /// Clearing the field falls back to the cheap browse query; making the
    /// user wait out the debounce for that would just read as a stall.
    func testClearingTheQueryAppliesWithoutWaitingOutTheDebounce() async {
        let clock = TestClock()
        let recorder = ClipboardWallQueryRecorder()
        let state = ClipboardWallState(
            presentation: makeRecordingPresentation(recorder),
            clock: clock
        )

        state.query = "swift"
        state.queryTextDidChange()
        await clock.advance(by: .milliseconds(150))
        await state.awaitPendingSearchForTesting()

        state.query = ""
        state.queryTextDidChange()
        await state.awaitPendingSearchForTesting()

        // Note the second entry landed without the clock moving at all.
        let texts = await recorder.queryTexts
        XCTAssertEqual(texts, ["swift", ""])
    }

    /// A category click is discrete and deliberate, and it carries whatever
    /// text is already typed, so a pending keystroke must not land after it.
    func testAFilterClickAppliesImmediatelyAndDropsAPendingKeystroke() async {
        let clock = TestClock()
        let recorder = ClipboardWallQueryRecorder()
        let state = ClipboardWallState(
            presentation: makeRecordingPresentation(recorder),
            clock: clock
        )

        state.query = "swift"
        state.queryTextDidChange()
        state.category = .kind(.image)
        state.filtersDidChange()
        await state.awaitPendingSearchForTesting()

        var recorded = await recorder.count
        XCTAssertEqual(recorded, 1)
        let query = await recorder.lastQuery
        XCTAssertEqual(query?.text, "swift")
        XCTAssertEqual(query?.facet, .image)

        // The cancelled keystroke must stay cancelled once its deadline passes.
        await clock.advance(by: .milliseconds(500))
        recorded = await recorder.count
        XCTAssertEqual(recorded, 1)
    }

    private func makeRecordingPresentation(
        _ recorder: ClipboardWallQueryRecorder
    ) -> ClipboardHistoryPresentationModel {
        ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { query, _ in
                    await recorder.record(query)
                    return ClipboardHistoryPage(entries: [], nextCursor: nil)
                },
                apply: { _ in .notFound },
                materialize: { _ in
                    ClipboardHistoryMaterialization(items: [])
                },
                tagDefinitions: { [] }
            )
        )
    }
}

/// A mutable page source, so a test can let the store change under an open
/// wall (a capture prepending an entry) between two loads.
private actor ClipboardWallEntryFeed {
    private var entries: [ClipboardHistoryEntry]

    init(_ entries: [ClipboardHistoryEntry]) {
        self.entries = entries
    }

    func replace(with entries: [ClipboardHistoryEntry]) {
        self.entries = entries
    }

    func page() -> ClipboardHistoryPage {
        ClipboardHistoryPage(entries: entries, nextCursor: nil)
    }
}

private actor ClipboardWallQueryRecorder {
    private var queries: [ClipboardHistoryQuery] = []

    func record(_ query: ClipboardHistoryQuery) {
        queries.append(query)
    }

    var lastQuery: ClipboardHistoryQuery? {
        queries.last
    }

    var queryTexts: [String] {
        queries.map(\.text)
    }

    var count: Int {
        queries.count
    }
}
