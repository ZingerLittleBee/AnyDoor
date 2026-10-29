import AppKit
import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardWorkingOutputSettingsTests: XCTestCase {
    func testReviewAndKeepAfterOffRestartPreservesChangedFilesWithoutSyncServices() async throws {
        let fixture = try await makeInterruptedDownload()
        let notices = try await fixture.receiver.workingOutputRecoveries()
        let notice = try XCTUnwrap(notices.first)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notice.reason, .incomplete)
        let member = notice.url.appendingPathComponent("member.txt")
        XCTAssertEqual(try Data(contentsOf: member), Data("interrupted folder contents".utf8))
        try await fixture.receiver.setSyncEnabled(false)
        let local = try await fixture.receiver.capture(.init(source: .unknown, content: .text("local history remains usable")))
        try await fixture.receiver.closeStoreForTesting()

        let changed = Data("user-edited partial file must survive".utf8)
        try changed.write(to: member)
        let reopened = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: fixture.receiverRoot,
            keyStore: FileConflictUILocalKey(byte: 0x42)))
        let model = ClipboardSyncSettingsModel(module: reopened)
        await model.refresh()
        XCTAssertEqual(model.workingOutputRecoveries.map(\.id), [notice.id])
        XCTAssertEqual(model.workingOutputRecoveries.first?.url, notice.url)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertFalse(model.operationFailed)

        await model.keepWorkingOutput(notice.id)
        XCTAssertTrue(model.workingOutputRecoveries.isEmpty)
        let retained = try await reopened.workingOutputRecoveries()
        XCTAssertTrue(retained.isEmpty)
        XCTAssertEqual(try Data(contentsOf: member), changed)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertFalse(model.operationFailed)
        let page = try await reopened.page(.init()).entries
        XCTAssertTrue(page.contains { $0.id == local.entryID && $0.previewText == "local history remains usable" })

        await model.keepWorkingOutput(notice.id)
        XCTAssertTrue(model.workingOutputRecoveries.isEmpty)
        XCTAssertFalse(model.operationFailed)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertEqual(try Data(contentsOf: member), changed)
    }

    func testFailedKeepPreservesTheRecordedReplacementAndDoesNotFollowTheMovedFile() async throws {
        let fixture = try await makeInterruptedDownload()
        try await fixture.receiver.setSyncEnabled(false)
        let notices = try await fixture.receiver.workingOutputRecoveries()
        let notice = try XCTUnwrap(notices.first)
        let moved = notice.url.appendingPathExtension("user-kept")
        try FileManager.default.moveItem(at: notice.url, to: moved)
        try FileManager.default.createDirectory(at: notice.url, withIntermediateDirectories: false)
        let replacement = notice.url.appendingPathComponent("replacement.txt")
        let replacementBytes = Data("unrelated replacement must remain untouched".utf8)
        try replacementBytes.write(to: replacement)

        let model = ClipboardSyncSettingsModel(module: fixture.receiver)
        await model.refresh()
        XCTAssertEqual(model.workingOutputRecoveries.first?.url, notice.url)
        XCTAssertEqual(model.workingOutputRecoveries.first?.reason, .changed)
        try await fixture.receiver.closeStoreForTesting()
        await model.keepWorkingOutput(notice.id)
        XCTAssertTrue(model.operationFailed)
        XCTAssertFalse(model.isPerformingAction)
        XCTAssertEqual(model.workingOutputRecoveries.map(\.id), [notice.id])

        let reopened = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: fixture.receiverRoot,
            keyStore: FileConflictUILocalKey(byte: 0x42)))
        let recoveredModel = ClipboardSyncSettingsModel(module: reopened)
        await recoveredModel.refresh()
        XCTAssertEqual(recoveredModel.workingOutputRecoveries.map(\.id), [notice.id])
        await recoveredModel.keepWorkingOutput(notice.id)
        XCTAssertTrue(recoveredModel.workingOutputRecoveries.isEmpty)
        XCTAssertFalse(recoveredModel.operationFailed)
        XCTAssertFalse(recoveredModel.status.isEnabled)
        XCTAssertEqual(try Data(contentsOf: replacement), replacementBytes)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("member.txt")), Data("interrupted folder contents".utf8))
    }

    private func makeInterruptedDownload() async throws -> (receiver: ClipboardHistoryModule, receiverRoot: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("working-output-ui-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let original = root.appendingPathComponent("Shared folder")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("interrupted folder contents".utf8).write(to: original.appendingPathComponent("member.txt"))
        let services = ClipboardSyncServices(transport: FileConflictUICloud(), keys: FileConflictUIKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: FileConflictUILocalKey(byte: 0x41), syncServices: services))
        let receiverRoot = root.appendingPathComponent("Receiver")
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: receiverRoot,
            keyStore: FileConflictUILocalKey(byte: 0x42),
            faultInjector: .init { $0 == .syncWorkingOutputDuringConstruction }, syncServices: services))
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.working-output-ui.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(original.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        try await sender.setSyncEnabled(false)
        return (receiver, receiverRoot)
    }
}
