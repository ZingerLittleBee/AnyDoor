import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardWallStateTests: XCTestCase {
    private func items(_ titles: [String]) -> [ClipboardHistoryItem] {
        titles.enumerated().map { idx, t in
            ClipboardHistoryItem(kind: .text, text: t, previewTitle: t,
                                 createdAt: Date(timeIntervalSinceReferenceDate: Double(idx)))
        }
    }

    func testSelectionClampsAndMoves() {
        let state = ClipboardWallState()
        state.setItems(items(["a", "b", "c"]))
        XCTAssertEqual(state.selectedIndex, 0)
        state.moveRight(); state.moveRight(); state.moveRight()   // clamps at last
        XCTAssertEqual(state.selectedIndex, 2)
        state.moveLeft()
        XCTAssertEqual(state.selectedIndex, 1)
        XCTAssertEqual(state.selectedItem?.previewTitle, "b")
    }

    func testCategoryAndSearchAreHeld() {
        let state = ClipboardWallState()
        state.category = .kind(.image)
        state.query = "foo"
        XCTAssertEqual(state.category, .kind(.image))
        XCTAssertEqual(state.query, "foo")
    }

    func testCategoryCyclingWrapsBothWays() {
        let state = ClipboardWallState()
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

    func testCyclingIncludesCustomTags() {
        let state = ClipboardWallState()
        let tags = [ClipboardTag(id: "t1", name: "工作")]
        state.setCategories(ClipboardWallState.order(tags: tags))
        state.selectNextCategory()   // .all → .favorites
        state.selectNextCategory()   // .favorites → .tag("t1")
        XCTAssertEqual(state.category, .tag("t1"))
    }

    func testSetCategoriesFallsBackToAllWhenActiveTagRemoved() {
        let state = ClipboardWallState()
        state.setCategories(ClipboardWallState.order(tags: [ClipboardTag(id: "t1", name: "工作")]))
        state.category = .tag("t1")
        state.setCategories(ClipboardWallState.order(tags: []))
        XCTAssertEqual(state.category, .all)
    }

    func testSetCategoriesKeepsActiveTagWhenStillPresent() {
        let state = ClipboardWallState()
        let tags = [ClipboardTag(id: "t1", name: "工作")]
        state.setCategories(ClipboardWallState.order(tags: tags))
        state.category = .tag("t1")
        state.setCategories(ClipboardWallState.order(tags: tags + [ClipboardTag(id: "t2", name: "生活")]))
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

    func testEmptyItemsHasNilSelection() {
        let state = ClipboardWallState()
        state.setItems([])
        XCTAssertNil(state.selectedItem)
        XCTAssertEqual(state.selectedIndex, 0)
    }
}
