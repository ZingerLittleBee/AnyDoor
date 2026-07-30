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
        entries: [ClipboardHistoryEntry] = []
    ) async -> ClipboardWallState {
        let page = ClipboardHistoryPage(
            entries: entries,
            nextCursor: nil
        )
        let presentation = ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { _, _ in page },
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
        let state = await makeState(entries: entries(["a", "b", "c"]))
        XCTAssertEqual(state.selectedIndex, 0)
        state.moveRight(); state.moveRight(); state.moveRight()   // clamps at last
        XCTAssertEqual(state.selectedIndex, 2)
        state.moveLeft()
        XCTAssertEqual(state.selectedIndex, 1)
        XCTAssertEqual(state.selectedItem?.previewText, "b")
    }

    func testCategoryAndSearchAreHeld() async {
        let state = await makeState()
        state.category = .kind(.image)
        state.query = "foo"
        state.sourceFilterBundleID = "com.apple.Safari"
        XCTAssertEqual(state.category, .kind(.image))
        XCTAssertEqual(state.query, "foo")
        XCTAssertEqual(state.sourceFilterBundleID, "com.apple.Safari")
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

    func testEmptyItemsHasNilSelection() async {
        let state = await makeState()
        XCTAssertNil(state.selectedItem)
        XCTAssertEqual(state.selectedIndex, 0)
    }

    func testClearingSourceFilterRestoresAllSources() async {
        let state = await makeState()
        state.sourceFilterBundleID = "com.apple.Safari"
        state.clearSourceFilter()
        XCTAssertNil(state.sourceFilterBundleID)
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
        state.sourceFilterBundleID = "com.example.Source"

        await state.refreshQuery()

        let query = await recorder.lastQuery
        XCTAssertEqual(query?.text, "needle")
        XCTAssertEqual(query?.facet, .image)
        XCTAssertEqual(query?.sourceID, "com.example.Source")
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
        var recorded = await recorder.count
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
