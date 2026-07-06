import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class ImageConversionHistoryStoreTests: XCTestCase {
    /// Retains the in-memory container for the test's lifetime; the store only
    /// holds the context, and a released container invalidates it.
    private var container: ModelContainer?

    private func makeStore() throws -> ImageConversionHistoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ImageConversionRecord.self, configurations: config)
        self.container = container
        return ImageConversionHistoryStore(modelContext: container.mainContext)
    }

    private func record(_ store: ImageConversionHistoryStore, name: String, at date: Date) {
        store.record(
            sourceName: name,
            sourceKind: .file,
            targetFormat: .jpeg,
            qualityPercent: 85,
            outputPath: "/tmp/\(name).jpg",
            createdAt: date
        )
    }

    func testRecordFetchesNewestFirst() throws {
        let store = try makeStore()
        record(store, name: "a", at: Date(timeIntervalSinceReferenceDate: 100))
        record(store, name: "b", at: Date(timeIntervalSinceReferenceDate: 200))
        record(store, name: "c", at: Date(timeIntervalSinceReferenceDate: 300))

        XCTAssertEqual(store.recent().map(\.sourceName), ["c", "b", "a"])
    }

    func testRecordPersistsAllFields() throws {
        let store = try makeStore()
        store.record(
            sourceName: "Photo.png",
            sourceKind: .bitmap,
            targetFormat: .heic,
            qualityPercent: 70,
            outputPath: "/tmp/out.heic",
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        let item = try XCTUnwrap(store.recent().first)
        XCTAssertEqual(item.sourceName, "Photo.png")
        XCTAssertEqual(item.sourceKind, ImageConversionSourceKind.bitmap.rawValue)
        XCTAssertEqual(item.targetFormat, ImageConversionFormat.heic.rawValue)
        XCTAssertEqual(item.qualityPercent, 70)
        XCTAssertEqual(item.outputPath, "/tmp/out.heic")
    }

    func testTrimsToFiftyOnWriteKeepingNewest() throws {
        let store = try makeStore()
        for index in 0..<55 {
            record(store, name: "\(index)", at: Date(timeIntervalSinceReferenceDate: Double(index)))
        }

        let recent = store.recent(limit: 100)
        XCTAssertEqual(recent.count, ImageConversionHistoryStore.capacity)
        // Newest first: 54 down to 5; the five oldest (0–4) were trimmed.
        XCTAssertEqual(recent.first?.sourceName, "54")
        XCTAssertEqual(recent.last?.sourceName, "5")
    }

    func testRevisionBumpsOnEveryWrite() throws {
        let store = try makeStore()
        let start = store.revision
        record(store, name: "a", at: Date(timeIntervalSinceReferenceDate: 100))
        record(store, name: "b", at: Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(store.revision, start &+ 2)
    }

    func testClearRemovesAllRecordsAndBumpsRevision() throws {
        let store = try makeStore()
        record(store, name: "a", at: Date(timeIntervalSinceReferenceDate: 100))
        record(store, name: "b", at: Date(timeIntervalSinceReferenceDate: 200))
        let revisionBeforeClear = store.revision

        store.clear()

        XCTAssertTrue(store.recent().isEmpty)
        XCTAssertEqual(store.revision, revisionBeforeClear &+ 1)
    }

    func testNoOpsWithoutContext() {
        let store = ImageConversionHistoryStore(modelContext: nil)
        record(store, name: "a", at: Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertTrue(store.recent().isEmpty)
        XCTAssertEqual(store.revision, 0)
    }
}
