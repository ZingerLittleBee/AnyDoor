import XCTest
@testable import ClipboardHistory
import ClipboardHistoryTestSupport
@testable import AnyDoor

@MainActor
final class ClipboardTextPanelModelTests: XCTestCase {
    func testDraftOpenedBeforeSharingRejectsAChangedBasisWithoutLosingTheDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-draft-sharing-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let services = ClipboardSyncServices(transport: FileConflictUICloud(), keys: FileConflictUIKeys(), pollingInterval: nil)
        let first = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("First"),
            keyStore: FileConflictUILocalKey(byte: 0x61), syncServices: services))
        let second = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Second"),
            keyStore: FileConflictUILocalKey(byte: 0x62), syncServices: services))
        let captured = try await first.capture(.init(source: .unknown, content: .text("unshared original")))
        let plan = try await first.textEditPlan(for: captured.entryID)
        let entry = try await first.page(.init()).entries.first
        let editor = ClipboardTextPanelModel(entry: try XCTUnwrap(entry), text: plan.text, isEditable: true)
        var dismissed = false
        editor.onDismiss = { dismissed = true }
        editor.onSave = { text in _ = try await first.saveTextEdit(text, using: plan) }
        editor.text = "draft from the original"

        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: captured.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let remotePlan = try await second.textEditPlan(for: captured.entryID)
        _ = try await second.saveTextEdit("remote change after sharing", using: remotePlan)
        await second.retrySync()
        await first.retrySync()
        let beforeSave = try await first.textEditPlan(for: captured.entryID)
        XCTAssertEqual(beforeSave.text, "remote change after sharing")

        await editor.save()

        XCTAssertFalse(dismissed)
        XCTAssertTrue(editor.saveFailed)
        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(editor.text, "draft from the original")
        let afterSave = try await first.textEditPlan(for: captured.entryID)
        XCTAssertEqual(afterSave.text, "remote change after sharing")
        XCTAssertEqual(afterSave.versions, beforeSave.versions)
    }

    func testConflictRequiresAnExplicitChoiceAndRefreshesAStaleChoice() async {
        let model = makeModel(text: "offline A", isEditable: true)
        let first = ClipboardHistoryTextVersion(id: UUID(), text: "offline A", editedAt: Date())
        let second = ClipboardHistoryTextVersion(id: UUID(), text: "offline B", editedAt: Date())
        let third = ClipboardHistoryTextVersion(id: UUID(), text: "offline C", editedAt: Date())
        model.conflictVersions = [first, second]
        var selected: UUID?
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.onResolve = { id in
            selected = id
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        model.reloadConflicts = { [first, second, third] }
        XCTAssertFalse(model.canSave)
        model.selectedVersionID = second.id
        await model.save()
        XCTAssertEqual(selected, second.id)
        XCTAssertFalse(dismissed)
        XCTAssertTrue(model.saveFailed)
        XCTAssertEqual(model.conflictVersions, [first, second, third])
        XCTAssertNil(model.selectedVersionID)
        model.onResolve = { id in selected = id }
        model.selectedVersionID = third.id
        await model.save()
        XCTAssertEqual(selected, third.id)
        XCTAssertTrue(dismissed)
    }

    func testFailedSaveKeepsTheDraftAndWaitsForSuccessfulRetry() async {
        let model = makeModel(text: "original", isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "unuploaded work"
        model.onSave = { _ in throw ClipboardHistoryModuleError.storageFailure }

        await model.save()

        XCTAssertFalse(dismissed)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.text, "unuploaded work")
        XCTAssertTrue(model.saveFailed)
        model.onSave = { text in XCTAssertEqual(text, "unuploaded work") }
        await model.save()
        XCTAssertTrue(dismissed)
        XCTAssertFalse(model.saveFailed)
    }

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

    /// The store refuses a zero-length edit and keeps a whitespace-only one
    /// (`ClipboardHistoryRetention.editText`, pinned by
    /// `ClipboardHistoryRetentionTests`), exactly as it treats a whitespace-only
    /// copy. Save has to draw the same line, or the panel refuses text the
    /// store would have kept.
    func testCanSaveRejectsOnlyZeroLengthText() {
        let model = makeModel(text: "hello", isEditable: true)
        model.text = ""
        XCTAssertFalse(model.canSave)
        model.text = "   \n\t"
        XCTAssertTrue(model.canSave)
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
