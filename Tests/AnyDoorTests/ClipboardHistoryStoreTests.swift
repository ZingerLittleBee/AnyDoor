import AppKit
import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardHistoryStoreTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ClipboardHistoryItem.self, configurations: config)
    }

    func testRecordTextReloadsNewestFirstForKindOnly() async throws {
        let container = try makeContainer()
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let store = ClipboardHistoryStore(now: { now })
        store.bootstrap(modelContainer: container)

        await store.recordText(kind: .ocr, text: "first")
        now = Date(timeIntervalSinceReferenceDate: 200)
        await store.recordText(kind: .qrcode, text: "qr")
        now = Date(timeIntervalSinceReferenceDate: 300)
        await store.recordText(kind: .ocr, text: "second\nline")

        await store.reload(kind: .ocr)
        XCTAssertEqual(store.items(for: .ocr).map(\.text), ["second\nline", "first"])
        XCTAssertEqual(store.items(for: .ocr).first?.previewTitle, "second")
    }

    func testRecordColorStoresColorHexAndNoText() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)

        await store.recordColor(hex: "#ffcc00")
        await store.reload(kind: .color)

        let item = try XCTUnwrap(store.items(for: .color).first)
        XCTAssertEqual(item.colorHex, "#FFCC00")
        XCTAssertNil(item.text)
        XCTAssertEqual(item.previewTitle, "#FFCC00")
    }

    func testPruneDeletesExpiredAndOverflowRows() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, maxItemsPerKind: 3)
        store.bootstrap(modelContainer: container)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired", previewTitle: "expired", createdAt: now.addingTimeInterval(-8 * 86_400)))
        for index in 0..<5 {
            context.insert(ClipboardHistoryItem(kind: .ocr, text: "\(index)", previewTitle: "\(index)", createdAt: now.addingTimeInterval(TimeInterval(index))))
        }
        try context.save()

        await store.pruneExpiredAndOverflow(force: true)
        await store.reload(kind: .ocr)

        XCTAssertEqual(store.items(for: .ocr).map(\.text), ["4", "3", "2"])
    }

    func testNonForcedPruneIsThrottled() async throws {
        let container = try makeContainer()
        var now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, pruneThrottle: 60)
        store.bootstrap(modelContainer: container)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired", previewTitle: "expired", createdAt: now.addingTimeInterval(-8 * 86_400)))
        try context.save()

        await store.pruneExpiredAndOverflow(force: false)
        now = now.addingTimeInterval(10)
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired2", previewTitle: "expired2", createdAt: now.addingTimeInterval(-8 * 86_400)))
        try context.save()
        await store.pruneExpiredAndOverflow(force: false)

        let rows = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
        XCTAssertTrue(rows.contains { $0.text == "expired2" })
    }

    func testRecordScreenshotStoresPngFileAndMetadata() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(
            now: { Date(timeIntervalSinceReferenceDate: 100) },
            historyDirectory: directory
        )
        store.bootstrap(modelContainer: container)

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))

        await store.recordScreenshotFromPasteboard()
        await store.reload(kind: .screenshot)

        let item = try XCTUnwrap(store.items(for: .screenshot).first)
        let fileName = try XCTUnwrap(item.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path))
        XCTAssertEqual(item.previewTitle, L(.clipboardKindScreenshot))

        try? FileManager.default.removeItem(at: directory)
    }

    func testCopyTextAndColorBackToPasteboard() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        let textItem = ClipboardHistoryItem(kind: .ocr, text: "hello", previewTitle: "hello")
        try await store.copyToPasteboard(textItem)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")

        let colorItem = ClipboardHistoryItem(kind: .color, colorHex: "#FFCC00", previewTitle: "#FFCC00")
        try await store.copyToPasteboard(colorItem)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "#FFCC00")

        try? FileManager.default.removeItem(at: directory)
    }

    func testClearAllResetsCacheEvenWhenNoRows() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        // Populate the cache via the public API, then wipe rows out-of-band so
        // clearAll() runs against an empty store with a stale cache present.
        await store.recordText(kind: .ocr, text: "stale")
        XCTAssertFalse(store.items(for: .ocr).isEmpty)

        let context = container.mainContext
        for item in try context.fetch(FetchDescriptor<ClipboardHistoryItem>()) {
            context.delete(item)
        }
        try context.save()

        await store.clearAll()

        for kind in ClipboardHistoryKind.allCases {
            XCTAssertTrue(store.items(for: kind).isEmpty)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func testClearAllDeletesRowsAndScreenshotFiles() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(historyDirectory: directory)
        store.bootstrap(modelContainer: container)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .screenshot, fileName: "shot.png", previewTitle: "截图"))
        try context.save()

        await store.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<ClipboardHistoryItem>()).isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }
}
