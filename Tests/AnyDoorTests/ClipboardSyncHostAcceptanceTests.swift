import AppKit
import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardSyncHostAcceptanceTests: XCTestCase {
    func testReceivedMixedEntryCopiesOnlyCompleteVersionsWithoutCaptureOrEcho() async throws {
        let fixture = try makeModules()
        let directory = fixture.root.appendingPathComponent("Shared complete directory")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
        let firstBytes = Data(repeating: 0x43, count: 5_500_001)
        let member = directory.appendingPathComponent("Nested/Contents.bin")
        try firstBytes.write(to: member)
        let rich = Data(#"{\rtf1\ansi rich copied text}"#.utf8)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 0x7F, count: 16)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let input = makePasteboard()
        defer { input.releaseGlobally() }
        let text = NSPasteboardItem(), image = NSPasteboardItem(), file = NSPasteboardItem()
        text.setString("rich copied text", forType: .string)
        text.setData(rich, forType: .rtf)
        image.setData(png, forType: .png)
        file.setString(directory.absoluteString, forType: .fileURL)
        XCTAssertTrue(input.writeObjects([text, image, file]))
        guard case .captured(let capture) = try await fixture.sender.capture(.init(pasteboard: input), source: .unknown) else {
            return XCTFail("Expected one ordered mixed entry")
        }
        let tag = try await fixture.sender.createTagDefinition(named: "Selected mixed entry", assigningTo: capture.entryID)
        try await fixture.sender.setSyncTagSelected(tag.definition.id, selected: true)
        let output = makePasteboard()
        defer { output.releaseGlobally() }
        output.setString("keep the existing clipboard", forType: .string)
        let initialGeneration = output.changeCount

        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)

        XCTAssertEqual(output.changeCount, initialGeneration)
        XCTAssertEqual(output.string(forType: .string), "keep the existing clipboard")
        let presentation = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await presentation.reload()
        let pending = await ClipboardHistoryPasteService.copyEntry(capture.entryID, from: presentation, to: output)
        XCTAssertEqual(pending, .materializationFailed(.syncFilesPending(entryID: capture.entryID, count: 1)))
        XCTAssertEqual(output.changeCount, initialGeneration)
        XCTAssertEqual(output.pasteboardItems?.count, 1, "Pending mixed entries must not produce a shortened paste")
        XCTAssertEqual(output.string(forType: .string), "keep the existing clipboard")
        let received = try await fixture.receiver.page(.init())
        let descriptor = try XCTUnwrap(received.entries.first?.syncFiles.first)
        XCTAssertGreaterThan(try XCTUnwrap(descriptor.originalByteCount), 5_000_000)
        try await fixture.receiver.requestSyncFileDownload(entryID: capture.entryID, objectID: descriptor.id, versionID: descriptor.versionID)
        _ = try await fixture.receiver.capture(.init(source: .unknown, content: .text("newer local recency sentinel")))
        let previousFunnel = ClipboardSelfWrites.current
        ClipboardSelfWrites.configure(fixture.receiver.pasteboardSelfWrites)
        defer { ClipboardSelfWrites.configure(previousFunnel) }
        let monitor = ClipboardHistoryCaptureMonitor(module: fixture.receiver, pasteboard: output,
            sourceProvider: { nil }, isKeychainUnlocked: { true }, installsSystemObservers: false)
        await fixture.receiver.installCaptureMonitorForTesting(monitor)
        await monitor.setEnabled(true)
        addTeardownBlock { await monitor.setEnabled(false) }
        let beforeCopy = try await fixture.receiver.page(.init())
        let uploadsBefore = await fixture.cloud.uploadCount()

        let copied = await ClipboardHistoryPasteService.copyEntry(capture.entryID, from: presentation, to: output)
        XCTAssertEqual(copied, .copied)
        let working = try assertCopiedEntry(output, rich: rich, png: png, bytes: firstBytes)
        await monitor.observeForTesting()
        await fixture.receiver.retrySync()

        let afterCopy = try await fixture.receiver.page(.init())
        XCTAssertEqual(afterCopy.entries, beforeCopy.entries, "Self-write observation must not create history, change recency, or rewrite provenance")
        let uploadsAfter = await fixture.cloud.uploadCount()
        XCTAssertEqual(uploadsAfter, uploadsBefore, "A received entry copied locally must not publish an echo")
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let nextBytes = Data(repeating: 0x71, count: 6_000_001)
        try nextBytes.write(to: member)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let nextPage = try await fixture.receiver.page(.init())
        let next = try XCTUnwrap(nextPage.entries.first { $0.id == capture.entryID }?.syncFiles.first)
        XCTAssertNotEqual(next.versionID, descriptor.versionID)
        XCTAssertEqual(next.availableVersionID, descriptor.versionID)
        XCTAssertEqual(try Data(contentsOf: working.appendingPathComponent("Nested/Contents.bin")), firstBytes)

        let olderCopy = await ClipboardHistoryPasteService.copyEntry(capture.entryID, from: presentation, to: output)
        XCTAssertEqual(olderCopy, .copied)
        _ = try assertCopiedEntry(output, rich: rich, png: png, bytes: firstBytes)
        await monitor.observeForTesting()
        try await fixture.receiver.requestSyncFileDownload(entryID: capture.entryID, objectID: next.id, versionID: next.versionID)
        let newerCopy = await ClipboardHistoryPasteService.copyEntry(capture.entryID, from: presentation, to: output)
        XCTAssertEqual(newerCopy, .copied)
        _ = try assertCopiedEntry(output, rich: rich, png: png, bytes: nextBytes)
        await monitor.observeForTesting()
        let finalPage = try await fixture.receiver.page(.init())
        XCTAssertEqual(finalPage.entries.map(\.id), beforeCopy.entries.map(\.id))
        XCTAssertEqual(finalPage.entries.first { $0.id == capture.entryID }?.source,
            beforeCopy.entries.first { $0.id == capture.entryID }?.source)
    }

    private func assertCopiedEntry(_ board: NSPasteboard, rich: Data, png: Data, bytes: Data) throws -> URL {
        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Array(items[0].types.prefix(2)), [.string, .rtf])
        XCTAssertEqual(items[0].string(forType: .string), "rich copied text")
        XCTAssertEqual(items[0].data(forType: .rtf), rich)
        // Capture canonicalizes bitmap encoding; compare decoded image content,
        // not encoder-specific PNG chunks or metadata ordering.
        let copiedImage = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(items[1].data(forType: .png))))
        let originalImage = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(copiedImage.pixelsWide, originalImage.pixelsWide)
        XCTAssertEqual(copiedImage.pixelsHigh, originalImage.pixelsHigh)
        for y in 0..<originalImage.pixelsHigh {
            for x in 0..<originalImage.pixelsWide {
                let expected = try XCTUnwrap(originalImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let actual = try XCTUnwrap(copiedImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 1.0 / 255)
            }
        }
        let directory = try XCTUnwrap(items[2].string(forType: .fileURL).flatMap(URL.init(string:)))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Nested/Contents.bin")), bytes)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Nested/Empty").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        return directory
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-host-acceptance.\(UUID())"))
    }

    private func makeModules() throws -> (root: URL, sender: ClipboardHistoryModule, receiver: ClipboardHistoryModule, cloud: FileConflictUICloud) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-host-acceptance-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cloud = FileConflictUICloud()
        let services = ClipboardSyncServices(transport: cloud, keys: FileConflictUIKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: FileConflictUILocalKey(byte: 0x41), syncServices: services))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Receiver"),
            keyStore: FileConflictUILocalKey(byte: 0x42), syncServices: services))
        return (root, sender, receiver, cloud)
    }
}
