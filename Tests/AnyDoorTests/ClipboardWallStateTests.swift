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
}

private actor ClipboardWallQueryRecorder {
    private var queries: [ClipboardHistoryQuery] = []

    func record(_ query: ClipboardHistoryQuery) {
        queries.append(query)
    }

    var lastQuery: ClipboardHistoryQuery? {
        queries.last
    }
}
