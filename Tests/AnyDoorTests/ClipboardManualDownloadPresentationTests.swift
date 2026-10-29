import AppKit
import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardManualDownloadPresentationTests: XCTestCase {
    func testManualDownloadReturnsWhileTransferIsHeldAndPublishesExactBytesLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manual-download-ui-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Large.bin")
        let bytes = Data(repeating: 0x6A, count: 6 * 1_024 * 1_024)
        try bytes.write(to: source)
        let cloud = FileConflictUICloud()
        let services = ClipboardSyncServices(transport: cloud, keys: FileConflictUIKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: FileConflictUILocalKey(byte: 0x71), syncServices: services))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Receiver"),
            keyStore: FileConflictUILocalKey(byte: 0x72), syncServices: services))
        addTeardownBlock { await cloud.releaseDownload() }
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.manual-download-ui.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.absoluteString, forType: .fileURL)
        guard case .captured(let captured) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected the owned large file")
        }
        let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: captured.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        let model = ClipboardHistoryPresentationModel(module: receiver)
        await model.reload()
        let file = try XCTUnwrap(model.entries.first?.syncFiles.first)
        XCTAssertEqual(file.state, .waitingForDownload)
        await cloud.holdNextDownload()
        var returned = false
        let request = Task {
            let failure = await model.transferSyncFile(file, entryID: captured.entryID)
            returned = true
            return failure
        }
        for _ in 0..<1_000 {
            if await cloud.downloadIsHeld() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let held = await cloud.downloadIsHeld()
        XCTAssertTrue(held)
        for _ in 0..<1_000 {
            if returned { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(returned, "The Host action must return after durable download consent, before body transfer finishes")
        await cloud.releaseDownload()
        let failure = await request.value
        XCTAssertNil(failure)
        var completed = false
        for _ in 0..<1_000 {
            let entry = try await receiver.page(.init()).entries.first
            if entry?.syncFiles.first?.state == .complete { completed = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(completed)
        let content = try await receiver.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        let output = try XCTUnwrap(content.fileURLs.first)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }
}
