import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardTextPanelModelTests: XCTestCase {
    private func makeItem(text: String) -> ClipboardHistoryItem {
        ClipboardHistoryItem(kind: .text, text: text, previewTitle: text)
    }

    func testCleanCloseDismissesWithoutConfirmation() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }

        model.requestClose()

        XCTAssertTrue(dismissed)
        XCTAssertFalse(model.showDiscardConfirm)
    }

    func testDirtyCloseShowsConfirmationInsteadOfDismissing() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "hello edited"

        model.requestClose()

        XCTAssertFalse(dismissed)
        XCTAssertTrue(model.showDiscardConfirm)
    }

    func testEscOnConfirmationKeepsEditing() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "hello edited"
        model.requestClose()

        // A second Esc while the overlay is up means "keep editing".
        model.requestClose()

        XCTAssertFalse(dismissed)
        XCTAssertFalse(model.showDiscardConfirm)
    }

    func testDiscardDismisses() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "hello edited"
        model.requestClose()

        model.discard()

        XCTAssertTrue(dismissed)
    }

    func testCanSaveRejectsWhitespaceOnlyText() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        model.text = "   \n\t"
        XCTAssertFalse(model.canSave)
        model.text = "ok"
        XCTAssertTrue(model.canSave)
    }

    func testPreviewModeIsNeverDirty() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: false)
        model.text = "mutated"
        XCTAssertFalse(model.isDirty)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.requestClose()
        XCTAssertTrue(dismissed)
    }

    func testReplaceSwapsContentAndResetsBaseline() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "first"), isEditable: false)
        model.replace(item: makeItem(text: "second"))
        XCTAssertEqual(model.text, "second")
        XCTAssertFalse(model.isDirty)
    }
}
