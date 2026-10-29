import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistoryPreviewRefreshTests: XCTestCase {
    func testReceivedTextRefreshesFullPreviewWhenItsVisiblePrefixIsUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-received-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let services = ClipboardSyncServices(transport: FileConflictUICloud(), keys: FileConflictUIKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: FileConflictUILocalKey(byte: 0x63), syncServices: services))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Receiver"),
            keyStore: FileConflictUILocalKey(byte: 0x64), syncServices: services))
        let prefix = String(repeating: "a", count: 4_096)
        let capture = try await sender.capture(.init(source: .unknown, content: .text(prefix + "before")))
        let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        let model = ClipboardHistoryPresentationModel(module: receiver)
        await model.reload()
        let originalPreview = model.entries.first?.previewText
        let initial = await model.materialization(for: capture.entryID, purpose: .fullPreview)
        XCTAssertEqual(initial?.exactTexts, [prefix + "before"])
        let plan = try await sender.textEditPlan(for: capture.entryID)
        _ = try await sender.saveTextEdit(prefix + "after", using: plan)

        await sender.retrySync()
        await receiver.retrySync()
        await model.refreshForStoreChange()

        XCTAssertEqual(model.entries.first?.previewText, originalPreview)
        let received = await model.materialization(for: capture.entryID, purpose: .fullPreview)
        XCTAssertEqual(received?.exactTexts, [prefix + "after"])
    }

    func testAReadFinishingAfterStoreRefreshCannotRestoreOldPreviewText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-inflight-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: FileConflictUILocalKey(byte: 0x62)))
        let capture = try await module.capture(.init(source: .unknown, content: .text("before")))
        let delivery = PreviewDeliveryGate()
        addTeardownBlock { await delivery.release() }
        let model = ClipboardHistoryPresentationModel(operations: .init(
            status: { await module.status() },
            page: { try await module.page($0, after: $1) },
            apply: { try await module.apply($0) },
            materialize: { request in
                let value = try await module.materialize(request)
                await delivery.holdFirstDelivery()
                return value
            },
            tagDefinitions: { try await module.tagDefinitions() }))
        await model.reload()
        let oldRead = Task { await model.materialization(for: capture.entryID, purpose: .fullPreview) }
        await delivery.waitUntilHeld()
        let plan = try await module.textEditPlan(for: capture.entryID)
        _ = try await module.saveTextEdit("after", using: plan)
        await model.refreshForStoreChange()
        await delivery.release()

        let oldResult = await oldRead.value
        let current = await model.materialization(for: capture.entryID, purpose: .fullPreview)

        XCTAssertNil(oldResult, "A superseded preview must not be displayed")
        XCTAssertEqual(current?.exactTexts, ["after"])
    }

    func testSavedTextRefreshesFullPreviewWhenItsVisiblePrefixIsUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-refresh-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: FileConflictUILocalKey(byte: 0x61)))
        let prefix = String(repeating: "a", count: 4_096)
        let capture = try await module.capture(.init(source: .unknown, content: .text(prefix + "before")))
        let presentation = ClipboardHistoryPresentationModel(module: module)
        await presentation.reload()
        let entry = try XCTUnwrap(presentation.entries.first)
        let initial = await presentation.materialization(for: entry.id, purpose: .fullPreview)
        XCTAssertEqual(initial?.exactTexts, [prefix + "before"])
        let plan = try await module.textEditPlan(for: capture.entryID)
        let editor = ClipboardTextPanelModel(entry: entry, text: plan.text, isEditable: true)
        editor.onSave = { text in _ = try await module.saveTextEdit(text, using: plan) }
        editor.text = prefix + "after"

        await editor.save()
        await presentation.refreshForStoreChange()

        XCTAssertFalse(editor.saveFailed)
        XCTAssertEqual(presentation.entries.first?.previewText, entry.previewText)
        let refreshed = await presentation.materialization(for: entry.id, purpose: .fullPreview)
        XCTAssertEqual(refreshed?.exactTexts, [prefix + "after"])
    }
}

private actor PreviewDeliveryGate {
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didHold = false

    func holdFirstDelivery() async {
        guard !didHold else { return }
        didHold = true
        await withCheckedContinuation { continuation in
            held = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
