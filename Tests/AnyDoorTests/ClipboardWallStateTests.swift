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
        state.category = .image
        state.query = "foo"
        XCTAssertEqual(state.category, .image)
        XCTAssertEqual(state.query, "foo")
    }

    func testEmptyItemsHasNilSelection() {
        let state = ClipboardWallState()
        state.setItems([])
        XCTAssertNil(state.selectedItem)
        XCTAssertEqual(state.selectedIndex, 0)
    }
}
