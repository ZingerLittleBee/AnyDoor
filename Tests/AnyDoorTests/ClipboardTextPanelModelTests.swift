import XCTest
import ClipboardHistory
@testable import AnyDoor

@MainActor
final class ClipboardTextPanelModelTests: XCTestCase {
    private func makeEntry(text: String) -> ClipboardHistoryEntry {
        ClipboardHistoryEntry(
            id: ClipboardHistoryEntryID(UUID()),
            capturedAt: Date(),
            previewText: text,
            facets: [.text],
            isFavorite: false,
            source: .unknown
        )
    }

    private func makeModel(
        text: String,
        isEditable: Bool
    ) -> ClipboardTextPanelModel {
        ClipboardTextPanelModel(
            entry: makeEntry(text: text),
            text: text,
            isEditable: isEditable
        )
    }

    func testCleanCloseDismissesWithoutConfirmation() {
        let model = makeModel(text: "hello", isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }

        model.requestClose()

        XCTAssertTrue(dismissed)
        XCTAssertFalse(model.showDiscardConfirm)
    }

    func testDirtyCloseShowsConfirmationInsteadOfDismissing() {
        let model = makeModel(text: "hello", isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "hello edited"

        model.requestClose()

        XCTAssertFalse(dismissed)
        XCTAssertTrue(model.showDiscardConfirm)
    }

    func testEscOnConfirmationKeepsEditing() {
        let model = makeModel(text: "hello", isEditable: true)
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
        let model = makeModel(text: "hello", isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "hello edited"
        model.requestClose()

        model.discard()

        XCTAssertTrue(dismissed)
    }

    func testCanSaveRejectsWhitespaceOnlyText() {
        let model = makeModel(text: "hello", isEditable: true)
        model.text = "   \n\t"
        XCTAssertFalse(model.canSave)
        model.text = "ok"
        XCTAssertTrue(model.canSave)
    }

    func testPreviewModeIsNeverDirty() {
        let model = makeModel(text: "hello", isEditable: false)
        model.text = "mutated"
        XCTAssertFalse(model.isDirty)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.requestClose()
        XCTAssertTrue(dismissed)
    }

    func testRequestEditFiresInPreviewMode() {
        let model = makeModel(text: "hello", isEditable: false)
        var fired = false
        model.onEditRequest = { fired = true }
        model.requestEdit()
        XCTAssertTrue(fired)
    }

    func testRequestEditIgnoredWhileEditing() {
        let model = makeModel(text: "hello", isEditable: true)
        var fired = false
        model.onEditRequest = { fired = true }
        model.requestEdit()
        XCTAssertFalse(fired)
    }

    func testReplaceSwapsContentAndResetsBaseline() {
        let model = makeModel(text: "first", isEditable: false)
        model.replace(entry: makeEntry(text: "second"), text: "second")
        XCTAssertEqual(model.text, "second")
        XCTAssertFalse(model.isDirty)
    }
}
