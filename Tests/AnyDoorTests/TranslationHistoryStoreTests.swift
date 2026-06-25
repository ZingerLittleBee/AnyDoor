import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class TranslationHistoryStoreTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TranslationRecord.self, configurations: config)
    }

    private func makeStore() throws -> (TranslationHistoryStore, ModelContainer) {
        let container = try makeContainer()
        let store = TranslationHistoryStore()
        store.configure(modelContainer: container)
        return (store, container)
    }

    private func insert(
        _ container: ModelContainer,
        text: String,
        favorite: Bool = false,
        at offset: TimeInterval
    ) throws {
        let record = TranslationRecord(
            sourceText: text,
            translatedText: "T-\(text)",
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: "google",
            serviceName: "Google",
            isFavorite: favorite,
            createdAt: Date(timeIntervalSinceReferenceDate: offset)
        )
        container.mainContext.insert(record)
        try container.mainContext.save()
    }

    func testRecordPersists() throws {
        let (store, container) = try makeStore()
        store.record(
            sourceText: "hello",
            translatedText: "你好",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google"
        )
        let rows = try container.mainContext.fetch(FetchDescriptor<TranslationRecord>())
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sourceText, "hello")
        XCTAssertEqual(row.translatedText, "你好")
        XCTAssertEqual(row.sourceLangCode, "en")
        XCTAssertEqual(row.targetLangCode, "zh-Hans")
        XCTAssertEqual(row.serviceID, "google")
    }

    func testRecordStoresRunID() throws {
        let (store, container) = try makeStore()
        store.record(
            sourceText: "hello",
            translatedText: "你好",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google",
            runID: "run-123"
        )
        let row = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).first)
        XCTAssertEqual(row.runID, "run-123")
    }

    func testRecordWithNilSourceStoresEmptyCode() throws {
        let (store, container) = try makeStore()
        store.record(
            sourceText: "hello",
            translatedText: "你好",
            source: nil,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google"
        )
        let row = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).first)
        XCTAssertEqual(row.sourceLangCode, "")
    }

    func testRecentNewestFirstAndLimit() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        try insert(container, text: "b", at: 200)
        try insert(container, text: "c", at: 300)

        XCTAssertEqual(store.recent(limit: 2).map(\.sourceText), ["c", "b"])
        XCTAssertEqual(store.recent(limit: 10).map(\.sourceText), ["c", "b", "a"])
    }

    func testFavoritesNewestFirst() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "plain", at: 100)
        try insert(container, text: "fav-old", favorite: true, at: 200)
        try insert(container, text: "fav-new", favorite: true, at: 300)

        XCTAssertEqual(store.favorites().map(\.sourceText), ["fav-new", "fav-old"])
    }

    func testToggleFavoriteFlips() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        let row = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertFalse(row.isFavorite)
        store.toggleFavorite(row)
        XCTAssertTrue(try XCTUnwrap(store.recent(limit: 1).first).isFavorite)
        store.toggleFavorite(row)
        XCTAssertFalse(try XCTUnwrap(store.recent(limit: 1).first).isFavorite)
    }

    func testDeleteRemovesRow() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        let row = try XCTUnwrap(store.recent(limit: 1).first)
        store.delete(row)
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).isEmpty)
    }

    func testSetFavoriteSetsWholeRunTogether() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        try insert(container, text: "b", at: 200)
        let rows = store.recent(limit: 10)
        XCTAssertEqual(rows.count, 2)
        store.setFavorite(rows, to: true)
        XCTAssertEqual(store.favorites().count, 2)
        store.setFavorite(rows, to: false)
        XCTAssertTrue(store.favorites().isEmpty)
    }

    func testDeleteRecordsRemovesWholeRun() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        try insert(container, text: "b", at: 200)
        store.delete(store.recent(limit: 10))
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).isEmpty)
    }

    func testClearRemovesAll() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        try insert(container, text: "b", at: 200)
        store.clear()
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).isEmpty)
    }

    func testTrimKeepsFavoritesAndNewestNonFavorites() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "old-fav", favorite: true, at: 100)
        try insert(container, text: "n1", at: 200)
        try insert(container, text: "n2", at: 300)
        try insert(container, text: "n3", at: 400)
        try insert(container, text: "n4", at: 500)

        // Keep the 2 newest non-favorites; the favorite is exempt regardless of age.
        store.trim(retention: 2)

        let survivors = Set(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).map(\.sourceText))
        XCTAssertEqual(survivors, ["old-fav", "n4", "n3"])
    }

    func testRecordEnforcesRetentionCap() throws {
        let (store, container) = try makeStore()
        // Seed 3 existing rows, then record 1 more with a cap of 3.
        try insert(container, text: "n1", at: 100)
        try insert(container, text: "n2", at: 200)
        try insert(container, text: "n3", at: 300)
        store.record(
            sourceText: "n4",
            translatedText: "T-n4",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google",
            retention: 3
        )
        // The oldest non-favorite (n1) is pruned to keep the newest 3.
        let survivors = Set(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).map(\.sourceText))
        XCTAssertEqual(survivors, ["n4", "n3", "n2"])
    }

    func testRecordWithDefaultRetentionKeepsEverything() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "n1", at: 100)
        // Default retention (0) means unlimited: the new row is kept alongside the old.
        store.record(
            sourceText: "n2",
            translatedText: "T-n2",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google"
        )
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).count, 2)
    }

    func testTrimZeroOrNegativeKeepsEverything() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        try insert(container, text: "b", at: 200)
        store.trim(retention: 0)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).count, 2)
    }

    // MARK: - Observable wiring

    func testRevisionBumpsOnEveryMutation() throws {
        let (store, container) = try makeStore()
        let start = store.revision

        // record (unlimited retention path)
        try insert(container, text: "a", at: 100)
        store.record(
            sourceText: "b",
            translatedText: "T-b",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google"
        )
        XCTAssertGreaterThan(store.revision, start)

        let afterRecord = store.revision
        let row = try XCTUnwrap(store.recent(limit: 1).first)

        store.toggleFavorite(row)
        XCTAssertGreaterThan(store.revision, afterRecord)

        let afterFavorite = store.revision
        store.delete(row)
        XCTAssertGreaterThan(store.revision, afterFavorite)

        let afterDelete = store.revision
        store.clear()
        XCTAssertGreaterThan(store.revision, afterDelete)
    }

    func testRevisionBumpsOnRecordWithRetentionAndTrim() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "n1", at: 100)
        let before = store.revision
        // The retention > 0 path delegates the bump to trim().
        store.record(
            sourceText: "n2",
            translatedText: "T-n2",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google",
            retention: 5
        )
        XCTAssertGreaterThan(store.revision, before)

        let afterRecord = store.revision
        store.trim(retention: 1)
        XCTAssertGreaterThan(store.revision, afterRecord)
    }

    func testNoContextIsSafe() {
        let store = TranslationHistoryStore()
        // No configure() call: every method must be a silent no-op, never crash.
        store.record(
            sourceText: "x",
            translatedText: "y",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google"
        )
        XCTAssertTrue(store.recent(limit: 5).isEmpty)
        XCTAssertTrue(store.favorites().isEmpty)
        store.clear()
    }
}
