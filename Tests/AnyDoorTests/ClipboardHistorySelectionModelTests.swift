import XCTest
import ClipboardHistory
@testable import AnyDoor

@MainActor
final class ClipboardHistorySelectionModelTests: XCTestCase {
    func testInitialSelectionUsesFirstItem() {
        let ids = [ClipboardHistoryEntryID(UUID()), ClipboardHistoryEntryID(UUID())]
        let model = ClipboardHistorySelectionModel()
        model.replaceItems(ids)
        XCTAssertEqual(model.selectedID, ids[0])
    }

    func testMoveSelectionClamps() {
        let ids = [
            ClipboardHistoryEntryID(UUID()),
            ClipboardHistoryEntryID(UUID()),
            ClipboardHistoryEntryID(UUID()),
        ]
        let model = ClipboardHistorySelectionModel()
        model.replaceItems(ids)
        model.moveDown()
        model.moveDown()
        model.moveDown()
        XCTAssertEqual(model.selectedID, ids[2])
        model.moveUp()
        XCTAssertEqual(model.selectedID, ids[1])
    }

    func testHoverSelectsItemAndSpaceTogglesPreview() {
        let id = ClipboardHistoryEntryID(UUID())
        let model = ClipboardHistorySelectionModel()
        model.replaceItems([id])
        model.select(id)
        XCTAssertEqual(model.selectedID, id)
        model.togglePreview()
        XCTAssertEqual(model.previewedID, id)
        model.togglePreview()
        XCTAssertNil(model.previewedID)
    }
}
