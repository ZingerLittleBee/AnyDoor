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
}
